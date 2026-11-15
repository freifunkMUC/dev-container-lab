-- LAB PROTOTYPE: multi-PoP active/standby on the node.
-- Not upstream firmware. dev-container-lab branch multipop-active-standby.
--
-- parker-as.sh runs this every 10 s, next to the stock noderoute. It reads
-- the extra fields the lab broker adds to noderoute.json:
--   primary_site = "muc"
--   sites = { muc = { range6, xlat_range6, address6, dns64, concentrator,
--                     pgws = { {name, pubkey, endpoint, address6, preferred}, ... } },
--             vie = {...} }
-- Tunnel wg_c<concentrator> goes to one pgw of the site at a time.
--
-- Health (per site, every 10 s): one ICMPv6 echo to the link-local address
-- of the pgw, sent out of wg_cX.
--   * 3 misses in a row: switch wg_cX to the next pgw of the same site. The
--     site stays up and its prefix stays preferred.
--   * the site is down when every pgw of the site missed 3 times in a row.
--     Going down is never delayed.
--   * the site is up again after 3 hits in a row, a handshake younger than
--     180 s and at least DWELL s in the down state.
--   * more than 3 up/down changes in 10 min: the site stays down for
--     PENALTY s.
--   * the active site is the primary site while it is up. After a failover
--     the node goes back to the primary only after it is up for HOLD_DOWN s.
--
-- What it sets:
--   * address6 of every site on br-client and (as /128) on wg_cX
--   * rules: 1000 main without default routes, 1050+ DNS64 of a site from
--     the node itself to the site table, 1100+ from <site /64> to the site
--     table. Each site table: default dev wg_cX (no next hop).
--   * main table: IPv6 and IPv4 default on the tunnel of the active site.
--     The IPv4 default selects the CLAT (one CLAT per tunnel, each with the
--     xlat /64 of its site).
--   * ip6tables chain parker_src for packets out of wg_c+ (FORWARD and
--     OUTPUT): a down site's /63 and any source that is not one of the
--     node's /63s get ICMPv6 code 5 (source address failed policy).
--   * RA (one patched uradvd, reads ra-state on SIGHUP and then sends 3 RAs):
--     active site 300/600, other up site 0/600, down site 0/600 for
--     DEAD_KEEP s, then not sent. RDNSS: the node addresses, active first.
--     PREF64 while a site is up.
--   * dnsmasq upstream servers: DNS64 of the up sites, active first.
--
-- "lua parker-as.lua pin <config.json>" (from nodeconfig.sh, before
-- nodeconfig.lua) puts the pgw in use into the concentrator of each site,
-- so that a config fetch does not undo a pgw switch.

local json = require("jsonc")

local TMPDIR = "/tmp/ff-Ohb0ba0u"
local CONF = TMPDIR .. "/noderoute.json"
local ROUTE4_FILE = TMPDIR .. "/noderoute-route4"
local STATE = "/tmp/parker-as"
local CLIENT_IF = "br-client"
local NAT64_PREFIX = "64:ff9b::/96"
local TABLE_BASE = 100

-- Defaults. /etc/parker-as.tune (json) can change them, for tests.
local T = {
  handshake_max_age = 180,
  misses_down = 3,
  hits_up = 3,
  dwell = 60,
  hold_down = 120,
  flap_window = 600,
  flap_max = 3,
  penalty = 600,
  preferred = 300,
  valid = 600,
  dead_keep = 180,
  keepalive = 25,
}

local function read(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local s = f:read("*a")
  f:close()
  return s
end

local function write(path, data)
  local f = assert(io.open(path .. ".tmp", "w"))
  f:write(data)
  f:close()
  os.rename(path .. ".tmp", path)
end

local function update_file(path, data)
  if read(path) == data then return false end
  write(path, data)
  return true
end

local function output(cmd)
  local p = io.popen(cmd .. " 2>/dev/null")
  local s = p:read("*a")
  p:close()
  return s
end

-- os.execute returns 0 on Lua 5.1 and true on 5.2+.
local function sh(cmd)
  local r = os.execute(cmd .. " >/dev/null 2>&1")
  return r == 0 or r == true
end

local function log(msg)
  sh("logger -t parker-as '" .. msg:gsub("'", "") .. "'")
end

local function net63(range6)
  return (range6:gsub("/64$", "/63"))
end

local function find_by(list, key, value)
  for i, item in ipairs(list or {}) do
    if tostring(item[key]) == tostring(value) then return item, i end
  end
  return nil
end

local function site_names(conf)
  local names = {}
  for name in pairs(conf.sites) do table.insert(names, name) end
  table.sort(names)
  return names
end

-- pin <config.json>: replace the concentrator of each site with the pinned pgw.
local function pin(path)
  local conf = json.parse(read(path) or "")
  if not conf or type(conf.sites) ~= "table" then return end
  local changed = false
  for name, site in pairs(conf.sites) do
    local pinned = read(STATE .. "/pgw." .. name)
    local pgw = pinned and find_by(site.pgws, "name", pinned)
    local conc = find_by(conf.concentrators, "id", site.concentrator)
    if pgw and conc and conc.pubkey ~= pgw.pubkey then
      for _, k in ipairs({ "address4", "address6", "endpoint", "pubkey" }) do
        if pgw[k] ~= nil then conc[k] = pgw[k] end
      end
      changed = true
    elseif pinned and not pgw then
      os.remove(STATE .. "/pgw." .. name)
    end
  end
  if changed then write(path, json.stringify(conf)) end
end

local function handshake_age(iface)
  local ts = tonumber(output("wg show " .. iface .. " latest-handshakes"):match("(%d+)%s*$") or "")
  if not ts or ts == 0 then return nil end
  return os.time() - ts
end

local function probe(iface, ll)
  if not ll then return false end
  return sh("ping -c 1 -W 2 -I " .. iface .. " " .. ll)
end

local function resolve(endpoint)
  local host, port = endpoint:match("^%[(.+)%]:(%d+)$")
  if host then return endpoint end
  host, port = endpoint:match("^(.+):(%d+)$")
  if not host or host:match("^[%d%.]+$") then return endpoint end
  local addr = nil
  for a in output("nslookup " .. host):gmatch("Address:?%s+([%x%.:]+)") do addr = a end
  if not addr then return nil end
  if addr:find(":", 1, true) then return "[" .. addr .. "]:" .. port end
  return addr .. ":" .. port
end

-- Move the tunnel of a site to another pgw. The prefix stays as it is.
local function switch_pgw(name, site, iface, pgw)
  local ep = resolve(pgw.endpoint)
  if not ep then
    log("site " .. name .. ": cannot resolve " .. pgw.endpoint)
    return false
  end
  for old in output("wg show " .. iface .. " peers"):gmatch("%S+") do
    sh("wg set " .. iface .. " peer " .. old .. " remove")
  end
  if not sh("wg set " .. iface .. " peer " .. pgw.pubkey .. " endpoint " .. ep
      .. " persistent-keepalive " .. T.keepalive .. " allowed-ips ::/0,0.0.0.0/0") then
    log("site " .. name .. ": wg set failed for " .. pgw.name)
    return false
  end
  write(STATE .. "/pgw." .. name, pgw.name)
  pin(CONF)
  log("site " .. name .. ": " .. iface .. " now uses pgw " .. pgw.name)
  return true
end

local function stock_radvd_args()
  local out = output("/lib/gluon/radvd/arguments")
  local skip = { ["-a"] = true, ["-p"] = true, ["--rdnss"] = true, ["-i"] = true,
    ["--preferred-lifetime"] = true, ["--valid-lifetime"] = true, ["--pref64"] = true }
  local result, drop = {}, false
  for tok in out:gmatch("%S+") do
    if drop then
      drop = false
    elseif skip[tok] then
      drop = true
    else
      table.insert(result, tok)
    end
  end
  return table.concat(result, " ")
end

local function uradvd_pid()
  for p in output("pidof uradvd"):gmatch("%d+") do
    if (read("/proc/" .. p .. "/cmdline") or ""):find("state-file", 1, true) then return p end
  end
  return nil
end

-- One step of the health state machine of a site. st is changed in place.
local function health(name, site, iface, st, now)
  local pgws = site.pgws or {}
  local current = output("wg show " .. iface .. " peers"):match("%S+")
  local pgw = current and find_by(pgws, "pubkey", current)
  local ll = pgw and pgw.address6 or nil
  if not ll then
    local conc = find_by(st.conf.concentrators, "id", site.concentrator)
    ll = conc and conc.address6
  end
  local age = handshake_age(iface)
  local fresh = age ~= nil and age < T.handshake_max_age
  if probe(iface, ll) then
    st.hits, st.misses = st.hits + 1, 0
  else
    st.hits, st.misses = 0, st.misses + 1
  end
  if st.hits >= T.hits_up and fresh then st.tried = 0 end

  -- 3 misses on this pgw: try the next pgw of the site.
  if st.misses >= T.misses_down then
    st.tried = st.tried + 1
    st.misses = 0
    if #pgws > 1 then
      local _, i = find_by(pgws, "pubkey", current or "")
      local next_pgw = pgws[((i or 0) % #pgws) + 1]
      if switch_pgw(name, site, iface, next_pgw) then pgw = next_pgw end
    end
  end

  local function change(to)
    st.state, st.since = to, now
    table.insert(st.changes, now)
    log("site " .. name .. " is " .. to)
  end
  local recent = {}
  for _, t in ipairs(st.changes) do
    if now - t < T.flap_window then table.insert(recent, t) end
  end
  st.changes = recent

  if st.state == "up" and st.tried >= math.max(#pgws, 1) then
    change("down")
  elseif st.state == "down" and st.hits >= T.hits_up and fresh
      and now - st.since >= T.dwell and now >= st.penalty_until then
    if #st.changes >= T.flap_max then
      st.penalty_until = now + T.penalty
      log("site " .. name .. " flaps: held down for " .. T.penalty .. " s")
    else
      change("up")
    end
  end
  st.fresh = fresh
  st.pgw = pgw and pgw.name or "?"
end

local function managed_prio(p)
  return p == 80 or p == 100 or (p >= 1000 and p < 1200)
end

local function apply_rules(want)
  local text = table.concat(want, "\n") .. "\n"
  local found = {}
  for line in output("ip -6 rule show"):gmatch("[^\n]+") do
    local p = tonumber(line:match("^(%d+):"))
    if p and managed_prio(p) then table.insert(found, p) end
  end
  if read(STATE .. "/rules") == text and #found == #want then return end
  for _, p in ipairs(found) do sh("ip -6 rule del pref " .. p) end
  for _, r in ipairs(want) do
    if not sh("ip -6 rule add " .. r) then log("ip -6 rule add " .. r .. " failed") end
  end
  write(STATE .. "/rules", text)
end

local function apply_firewall(conf, names, up)
  -- The pgw probe goes to a link-local address with the site address as
  -- source. It must pass also while the site is down.
  local want = { "-N parker_src", "-A parker_src -d fe80::/10 -j RETURN" }
  for _, name in ipairs(names) do
    if not up[name] then
      table.insert(want, "-A parker_src -s " .. net63(conf.sites[name].range6)
        .. " -j REJECT --reject-with icmp6-policy-fail")
    end
  end
  for _, name in ipairs(names) do
    if up[name] then
      table.insert(want, "-A parker_src -s " .. net63(conf.sites[name].range6) .. " -j RETURN")
    end
  end
  table.insert(want, "-A parker_src -s fe80::/10 -j RETURN")
  table.insert(want, "-A parker_src -j REJECT --reject-with icmp6-policy-fail")
  -- Compare with the kernel each time: a firewall reload removes the chain.
  local have = output("ip6tables -S parker_src"):gsub("/128", ""):gsub("%s+\n", "\n")
  local norm = table.concat(want, "\n") .. "\n"
  if have ~= norm then
    sh("ip6tables -N parker_src")
    sh("ip6tables -F parker_src")
    for i = 2, #want do
      if not sh("ip6tables " .. want[i]) then log("ip6tables " .. want[i] .. " failed") end
    end
  end
  for _, chain in ipairs({ "FORWARD", "OUTPUT" }) do
    if not sh("ip6tables -C " .. chain .. " -o wg_c+ -j parker_src") then
      sh("ip6tables -I " .. chain .. " 1 -o wg_c+ -j parker_src")
    end
  end
end

local function main()
  sh("mkdir -p " .. STATE)
  local tune = json.parse(read("/etc/parker-as.tune") or "") or {}
  for k, v in pairs(tune) do if T[k] ~= nil then T[k] = tonumber(v) end end

  local conf = json.parse(read(CONF) or "")
  if not conf or type(conf.sites) ~= "table" or not conf.primary_site then
    write(STATE .. "/status", "no multipop config\n")
    return
  end
  local names = site_names(conf)
  local now = os.time()
  local db = json.parse(read(STATE .. "/state.json") or "") or {}
  db.sites = db.sites or {}

  local iface, tbl, up = {}, {}, {}
  for i, name in ipairs(names) do
    local site = conf.sites[name]
    tbl[name] = TABLE_BASE + i
    local st = db.sites[name] or {}
    st.state = st.state or "down"
    st.since = st.since or 0
    st.hits, st.misses, st.tried = st.hits or 0, st.misses or 0, st.tried or 0
    st.changes, st.penalty_until = st.changes or {}, st.penalty_until or 0
    db.sites[name] = st
    if site.concentrator then
      iface[name] = "wg_c" .. tostring(site.concentrator)
      if sh("ip link show " .. iface[name]) then
        -- The site address as /128 on the tunnel: the probe source.
        sh("ip -6 addr replace " .. site.address6 .. "/128 dev " .. iface[name])
        sh("ip -6 route replace fe80::/64 dev " .. iface[name])
        st.conf = conf
        health(name, site, iface[name], st, now)
        st.conf = nil
      else
        iface[name] = nil
        if st.state == "up" then st.state, st.since = "down", now end
      end
    end
    up[name] = st.state == "up"
  end

  -- The active site: the primary while it is up (after HOLD_DOWN when the
  -- node comes back to it), else the active one, else the first up site.
  local active = db.active
  local p = db.sites[conf.primary_site]
  if up[conf.primary_site] and (active == conf.primary_site or not up[active or ""]
      or now - p.since >= T.hold_down) then
    active = conf.primary_site
  elseif not up[active or ""] then
    active = nil
    for _, name in ipairs(names) do
      if up[name] then active = name break end
    end
  end
  if active ~= db.active then
    log("active site: " .. tostring(db.active) .. " -> " .. tostring(active))
    db.active = active
  end

  -- Addresses, rules and site tables.
  local rules = { "pref 1000 lookup main suppress_prefixlength 0" }
  for i, name in ipairs(names) do
    local site = conf.sites[name]
    sh("ip -6 addr replace " .. site.address6 .. "/64 dev " .. CLIENT_IF)
    if iface[name] then
      sh("ip -6 route replace default dev " .. iface[name] .. " src " .. site.address6
        .. " table " .. tbl[name])
      if site.dns64 then
        table.insert(rules, "pref " .. (1050 + i) .. " to " .. site.dns64 .. " iif lo lookup " .. tbl[name])
      end
      table.insert(rules, "pref " .. (1100 + i) .. " from " .. site.range6 .. " lookup " .. tbl[name])
    end
  end
  apply_rules(rules)
  apply_firewall(conf, names, up)

  -- Default routes of the node on the tunnel of the active site. Keep the
  -- MTU and the record of noderoute, so noderoute takes the route as its own.
  if active and iface[active] then
    sh("ip -6 route replace default dev " .. iface[active] .. " proto 23")
    local conc = find_by(conf.concentrators, "id", conf.sites[active].concentrator)
    local route4 = read(ROUTE4_FILE)
    if conc and conc.address4 and route4 and not route4:find("dev " .. iface[active] .. " ", 1, true) then
      local new = "default via " .. conc.address4 .. " dev " .. iface[active] .. " proto 23"
      local mtu = route4:match("mtu (%d+)")
      if mtu then new = new .. " mtu " .. mtu end
      if sh("ip -4 route replace " .. new) then
        write(ROUTE4_FILE, new)
        log("IPv4 default moved to " .. iface[active])
      end
    end
  end

  -- CLAT: each tunnel translates into the xlat /64 of its own site.
  local clat_changed = false
  for _, name in ipairs(names) do
    local xlat = conf.sites[name].xlat_range6
    if iface[name] and xlat then
      clat_changed = update_file("/tmp/xlat_range6." .. iface[name], xlat) or clat_changed
    end
  end
  if clat_changed then sh("/etc/init.d/ebpf-clat restart") end

  -- RA state: active site first.
  local order = {}
  if active then table.insert(order, active) end
  for _, name in ipairs(names) do
    if name ~= active then table.insert(order, name) end
  end
  local lines, rdnss = {}, {}
  for _, name in ipairs(order) do
    local site, st = conf.sites[name], db.sites[name]
    if up[name] or now - st.since < T.dead_keep then
      local preferred = (name == active) and T.preferred or 0
      table.insert(lines, site.range6 .. "," .. preferred .. "," .. T.valid)
      table.insert(rdnss, "rdnss " .. site.address6)
    end
  end
  for _, r in ipairs(rdnss) do table.insert(lines, r) end
  local ra_state = table.concat(lines, "\n") .. "\n"
  local stock = stock_radvd_args()
  local ra_args = "-i " .. CLIENT_IF .. (stock ~= "" and (" " .. stock) or "")
  if active then ra_args = ra_args .. " --pref64 " .. NAT64_PREFIX end
  local restart = update_file(STATE .. "/ra-args", ra_args .. "\n")
  local pid = uradvd_pid()
  if update_file(STATE .. "/ra-state", ra_state) or restart or not pid then
    if pid and not restart then
      sh("kill -HUP " .. pid)
    else
      sh("/etc/init.d/gluon-radvd restart")
    end
    log("RA: " .. ra_state:gsub("\n", ";") .. " active " .. tostring(active))
  end

  -- dnsmasq: the DNS64 of each up site, active first.
  local servers = {}
  for _, name in ipairs(order) do
    if up[name] and conf.sites[name].dns64 then
      table.insert(servers, "server=" .. conf.sites[name].dns64)
    end
  end
  local servers_file = STATE .. "/dns-servers"
  if update_file(servers_file, table.concat(servers, "\n") .. "\n") then
    if output("uci -q get dhcp.@dnsmasq[0].serversfile"):match("%S+") ~= servers_file then
      sh("uci -q delete dhcp.@dnsmasq[0].server")
      sh("uci set dhcp.@dnsmasq[0].serversfile=" .. servers_file)
      sh("uci commit dhcp")
      sh("/etc/init.d/dnsmasq restart")
    else
      sh("/etc/init.d/dnsmasq reload")
    end
    log("DNS servers: " .. table.concat(servers, " "))
  end

  write(STATE .. "/state.json", json.stringify(db))
  local status = { "primary_site=" .. conf.primary_site, "active=" .. tostring(active) }
  for _, name in ipairs(names) do
    local st = db.sites[name]
    table.insert(status, "site " .. name .. " " .. st.state .. " iface=" .. tostring(iface[name])
      .. " pgw=" .. tostring(st.pgw) .. " hits=" .. st.hits .. " misses=" .. st.misses
      .. " tried=" .. st.tried .. " fresh=" .. tostring(st.fresh)
      .. " penalty=" .. tostring(st.penalty_until > now)
      .. " range6=" .. conf.sites[name].range6
      .. " ra=" .. (ra_state:find(conf.sites[name].range6 .. ",", 1, true) and "on" or "off"))
  end
  write(STATE .. "/status", table.concat(status, "\n") .. "\n")
end

if arg[1] == "pin" then
  pin(arg[2])
else
  main()
end
