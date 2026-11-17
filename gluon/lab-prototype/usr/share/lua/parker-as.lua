-- LAB PROTOTYPE: multi-PoP active/standby on the node.
-- Not upstream firmware. dev-container-lab branch multipop-active-standby.
--
-- parker-as.sh starts this as a daemon ("loop"), next to the stock
-- noderoute. One tick is 1 s. It reads
-- the extra fields the lab broker adds to noderoute.json:
--   primary_site = "muc"
--   sites = { muc = { range6, xlat_range6, address6, dns64, concentrator,
--                     pgws = { {name, pubkey, endpoint, address6, preferred}, ... } },
--             vie = {...} }
-- Tunnel wg_c<concentrator> goes to one pgw of the site at a time.
--
-- Health (per site, every tick): one ICMPv6 echo (1 s timeout) to the
-- address6 of the current pgw, sent out of wg_cX (wg-nodes on the pgw has no
-- link-local address). The reject chain lets the probe pass also while the
-- site is down. All sites are probed at the same time.
--   * 3 misses in a row (about 3 s): switch wg_cX to the next pgw of the
--     same site. The site stays up and its prefix stays preferred. After a
--     fresh handshake with the new pgw, the node reports the switch to the
--     broker (/api/v3/lab/switch). The broker tells the old pgw to remove
--     the node /63 at once.
--   * the site is down when every pgw of the site missed 3 times in a row.
--     Going down is never delayed.
--   * the site is up again after 3 hits in a row and a handshake younger
--     than 180 s, and when this stays true for DWELL s (10 s).
--   * more than 3 up/down changes in 10 min: the site stays down for a
--     penalty. The penalty starts at PENALTY s and doubles for each new
--     penalty, up to PENALTY_MAX s. A quiet FLAP_WINDOW resets it.
--   * the active site is the primary site while it is up, else the first up
--     site. There is no hold-down.
--
-- A tick only probes. The full apply below runs when a state, the active
-- site, a pgw or the config changes, and every 10 s. Each tick also checks
-- the client path of each site (route get from the pgw into br-client). A
-- netifd reload removes the site addresses; the tick adds them again and
-- logs client_path_broken.
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
--     PREF64 while a site is up. Router lifetime 30 s, an RA every 5-10 s.
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
  dwell = 10,
  flap_window = 600,
  flap_max = 3,
  penalty = 60,
  penalty_max = 600,
  full_every = 10,
  report_retry = 3,
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

local function is_link(iface)
  return iface ~= nil and read("/sys/class/net/" .. iface .. "/ifindex") ~= nil
end

-- One tick of 1 s: probe all tunnels at the same time and read the
-- handshakes. Returns ok[iface] = true and wg[iface] = {peer, ts}.
local function probe_all(targets)
  local parts = { "sleep 1 &" }
  for iface, ll in pairs(targets) do
    table.insert(parts, "(ping -c 1 -W 1 -I " .. iface .. " " .. ll
      .. " >/dev/null 2>&1 && echo ok " .. iface .. ") &")
  end
  table.insert(parts, "wg show all latest-handshakes; wait")
  local ok, wg = {}, {}
  for line in output(table.concat(parts, " ")):gmatch("[^\n]+") do
    local i = line:match("^ok (%S+)$")
    if i then
      ok[i] = true
    else
      local w, peer, ts = line:match("^(%S+)%s+(%S+)%s+(%d+)$")
      if w and not wg[w] then wg[w] = { peer = peer, ts = tonumber(ts) } end
    end
  end
  return ok, wg
end

local function urlencode(v)
  return (tostring(v):gsub("[^%w%-%._~]", function(c) return string.format("%%%02X", c:byte()) end))
end

-- Tell the broker that the site now uses pgw (in the background).
local function report_switch(name, iface, pgw)
  local server = output("uci -q get parker.nodeconfig.config_server"):match("%S+")
  local key = output("wg show " .. iface .. " public-key"):match("%S+")
  if not server or not key then return end
  if not server:find("://", 1, true) then server = "http://" .. server end
  local url = server .. "/api/v3/lab/switch?pubkey=" .. urlencode(key)
    .. "&site=" .. urlencode(name) .. "&pgw=" .. urlencode(pgw)
  local done = STATE .. "/report." .. name
  -- As nodeconfig.sh: out over the WAN (packet mark 1), and the server name
  -- resolves through the WAN resolver (gluon-wan-dns), not the tunnel DNS64.
  os.execute("(LIBPACKETMARK_MARK=1 LD_PRELOAD=libpacketmark.so gluon-wan-dns wget -q -T 3"
    .. " -O /dev/null '" .. url .. "' && echo " .. pgw .. " > " .. done
    .. " || logger -t parker-as 'site " .. name .. ": report of " .. pgw
    .. " failed, exit '$?) >/dev/null 2>&1 &")
end

local function resolve(endpoint)
  local host, port = endpoint:match("^%[(.+)%]:(%d+)$")
  if host then return endpoint end
  host, port = endpoint:match("^(.+):(%d+)$")
  if not host or host:match("^[%d%.]+$") then return endpoint end
  -- The pgw names resolve only on the WAN (the local dnsmasq forwards to the
  -- site DNS64). gluon-wan-dns sends the query to the WAN resolver. The
  -- WAN is IPv4, so ask for A only. Skip the "Server:" block: busybox prints
  -- "Address: <server>:53" there, also on NXDOMAIN.
  local out = output("gluon-wan-dns nslookup -type=a " .. host .. " 2>/dev/null")
  local answer = out:match("\nName:.*$") or ""
  local addr = answer:match("Address:?%s+(%d+%.%d+%.%d+%.%d+)")
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
-- ok: the probe of this tick answered. wg: {peer, ts} of the tunnel.
local function health(name, site, iface, st, now, ok, wg)
  local pgws = site.pgws or {}
  local current = wg and wg.peer
  local pgw = current and find_by(pgws, "pubkey", current)
  local fresh = wg ~= nil and wg.ts > 0 and now - wg.ts < T.handshake_max_age
  if ok then
    st.hits, st.misses = st.hits + 1, 0
  else
    st.hits, st.misses = 0, st.misses + 1
  end
  local good = st.hits >= T.hits_up and fresh
  if good then st.tried = 0 end
  st.good_since = good and (st.good_since or now) or nil

  -- 3 misses on this pgw: try the next pgw of the site.
  if st.misses >= T.misses_down then
    st.tried = st.tried + 1
    st.misses = 0
    if #pgws > 1 then
      local _, i = find_by(pgws, "pubkey", current or "")
      local next_pgw = pgws[((i or 0) % #pgws) + 1]
      if switch_pgw(name, site, iface, next_pgw) then
        pgw = next_pgw
        st.switched = true
        st.report = { pgw = next_pgw.name, since = now, last = 0 }
        os.remove(STATE .. "/report." .. name)
      end
    end
  end

  -- Report the switch after a handshake with the new pgw.
  if st.report then
    if (read(STATE .. "/report." .. name) or ""):match("%S+") == st.report.pgw then
      log("site " .. name .. ": broker knows pgw " .. st.report.pgw .. " ("
        .. (now - st.report.since) .. " s)")
      st.report = nil
    elseif wg and pgw and pgw.name == st.report.pgw and wg.ts >= st.report.since
        and now - st.report.last >= T.report_retry then
      st.report.last = now
      report_switch(name, iface, st.report.pgw)
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
  if #recent == 0 and now >= st.penalty_until then st.penalties = 0 end

  if st.state == "up" and st.tried >= math.max(#pgws, 1) then
    change("down")
  elseif st.state == "down" and st.good_since and now - st.good_since >= T.dwell
      and now >= st.penalty_until then
    if #st.changes >= T.flap_max then
      local hold = math.min(T.penalty * 2 ^ st.penalties, T.penalty_max)
      st.penalties = st.penalties + 1
      st.penalty_until = now + hold
      st.changes = {}
      log("site " .. name .. " flaps: held down for " .. hold .. " s")
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
  -- The pgw probe goes to the pgw address (wg-nodes has no link-local
  -- address) with the site address as source. It must pass also while the
  -- site is down, else a down site never comes up.
  local want = { "-N parker_src", "-A parker_src -d fe80::/10 -j RETURN" }
  for _, name in ipairs(names) do
    for _, pgw in ipairs(conf.sites[name].pgws or {}) do
      if pgw.address6 then
        table.insert(want, "-A parker_src -d " .. pgw.address6 .. " -j RETURN")
      end
    end
  end
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

local apply

-- One tick. db is kept in memory by the loop (and in state.json).
local function tick(db)
  sh("mkdir -p " .. STATE)
  local tune = json.parse(read("/etc/parker-as.tune") or "") or {}
  for k, v in pairs(tune) do if T[k] ~= nil then T[k] = tonumber(v) end end

  local raw = read(CONF) or ""
  local conf = json.parse(raw)
  if not conf or type(conf.sites) ~= "table" or not conf.primary_site then
    write(STATE .. "/status", "no multipop config\n")
    sh("sleep 1")
    return
  end
  local names = site_names(conf)
  db.sites = db.sites or {}

  local iface, tbl, up, targets = {}, {}, {}, {}
  for i, name in ipairs(names) do
    local site = conf.sites[name]
    tbl[name] = TABLE_BASE + i
    local st = db.sites[name] or {}
    st.state = st.state or "down"
    st.since = st.since or 0
    st.hits, st.misses, st.tried = st.hits or 0, st.misses or 0, st.tried or 0
    st.changes, st.penalty_until = st.changes or {}, st.penalty_until or 0
    st.penalties = st.penalties or 0
    db.sites[name] = st
    local i_name = site.concentrator and ("wg_c" .. tostring(site.concentrator))
    if is_link(i_name) then
      iface[name] = i_name
      local current = output("wg show " .. i_name .. " peers"):match("%S+")
      local pgw = current and find_by(site.pgws, "pubkey", current)
      local conc = find_by(conf.concentrators, "id", site.concentrator)
      targets[i_name] = (pgw and pgw.address6) or (conc and conc.address6) or nil
    end
  end

  local ok, wg = probe_all(targets)
  local now = os.time()
  local changed = raw ~= db.raw or now - (db.full or 0) >= T.full_every
  for _, name in ipairs(names) do
    local st = db.sites[name]
    local before = st.state .. (st.pgw or "")
    if iface[name] then
      health(name, conf.sites[name], iface[name], st, now, ok[iface[name]], wg[iface[name]])
    elseif st.state == "up" then
      st.state, st.since = "down", now
      log("site " .. name .. " is down (no tunnel)")
    end
    if st.switched or before ~= st.state .. (st.pgw or "") then changed = true end
    st.switched = nil
    up[name] = st.state == "up"
  end

  -- The active site: the primary while it is up, else the active one, else
  -- the first up site.
  local active = db.active
  if up[conf.primary_site] then
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
    changed = true
  end

  -- A netifd reload of the client interface removes the site addresses on
  -- br-client. Then replies to clients go out of the wrong tunnel, while the
  -- probe (from the /128 on wg_cX) still works. Check the client path every
  -- cycle and add the address again.
  db.path_broken = db.path_broken or 0
  for _, name in ipairs(names) do
    local site, i_name = conf.sites[name], iface[name]
    local base = site.range6:match("^(.*::)/64$")
    if i_name and targets[i_name] and base then
      local route = output("ip -6 route get " .. base .. "5a5a:1234 from " .. targets[i_name]
        .. " iif " .. i_name .. " 2>&1")
      if not route:find("dev " .. CLIENT_IF .. " ", 1, true) then
        -- No nodad: the stock firmware has the BusyBox ip, which rejects it.
        local added = sh("ip -6 addr replace " .. site.address6 .. "/64 dev " .. CLIENT_IF)
        db.path_broken = db.path_broken + 1
        log("client_path_broken site " .. name .. (added and "" or " (repair failed)") .. ": "
          .. route:gsub("\n", " "))
        changed = true
      end
    end
  end

  if changed then
    db.raw, db.full = raw, now
    apply(conf, names, db, iface, tbl, up, active, now)
  end
  local status = { "primary_site=" .. conf.primary_site, "active=" .. tostring(active),
    "path_broken=" .. db.path_broken }
  local ra_state = read(STATE .. "/ra-state") or ""
  for _, name in ipairs(names) do
    local st = db.sites[name]
    table.insert(status, "site " .. name .. " " .. st.state .. " iface=" .. tostring(iface[name])
      .. " pgw=" .. tostring(st.pgw) .. " hits=" .. st.hits .. " misses=" .. st.misses
      .. " tried=" .. st.tried .. " fresh=" .. tostring(st.fresh)
      .. " penalty=" .. tostring(st.penalty_until > now)
      .. " report=" .. (st.report and "pending" or "none")
      .. " range6=" .. conf.sites[name].range6
      .. " ra=" .. (ra_state:find(conf.sites[name].range6 .. ",", 1, true) and "on" or "off"))
  end
  update_file(STATE .. "/status", table.concat(status, "\n") .. "\n")
end

-- Addresses, rules, firewall, routes, CLAT, RA and DNS for the current state.
apply = function(conf, names, db, iface, tbl, up, active, now)

  -- Addresses, rules and site tables.
  local rules = { "pref 1000 lookup main suppress_prefixlength 0" }
  for i, name in ipairs(names) do
    local site = conf.sites[name]
    sh("ip -6 addr replace " .. site.address6 .. "/64 dev " .. CLIENT_IF)
    if iface[name] then
      -- The site address as /128 on the tunnel: the probe source.
      sh("ip -6 addr replace " .. site.address6 .. "/128 dev " .. iface[name])
      sh("ip -6 route replace fe80::/64 dev " .. iface[name])
      -- Probe targets: each pgw of the site through the site tunnel, also
      -- while the main default route is on the other tunnel.
      for _, pgw in ipairs(site.pgws or {}) do
        if pgw.address6 then
          sh("ip -6 route replace " .. pgw.address6 .. "/128 dev " .. iface[name])
        end
      end
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
  -- Router lifetime 30 s, an RA every 5-10 s: br-client bridges bat0, and
  -- Gluon keeps RAs off bat0. So after a roam the old node stays the router
  -- of the client (through the mesh) until the router lifetime ends, and its
  -- parker_src rejects the prefixes of the new node.
  local ra_args = "-i " .. CLIENT_IF .. (stock ~= "" and (" " .. stock) or "")
    .. " --default-lifetime 30 --max-router-adv-interval 10 --min-router-adv-interval 5"
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
end

if arg[1] == "pin" then
  pin(arg[2])
else
  -- "loop": the daemon (parker-as.sh). Without an argument: one tick.
  local db = json.parse(read(STATE .. "/state.json") or "") or {}
  db.raw, db.full = nil, nil
  repeat
    local okay, err = pcall(tick, db)
    if not okay then
      log("tick failed: " .. tostring(err))
      sh("sleep 1")
    end
  until arg[1] ~= "loop"
end
