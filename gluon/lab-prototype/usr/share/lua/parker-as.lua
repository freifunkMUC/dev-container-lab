-- LAB PROTOTYPE: multi-PoP active/standby on the node.
-- Not upstream firmware. dev-container-lab branch multipop-active-standby.
--
-- Runs every few seconds next to the stock noderoute. Reads the extra fields
-- the lab broker adds to noderoute.json:
--   primary_site = "muc"
--   sites = { muc = { range6, xlat_range6, address6, dns64, concentrator }, vie = {...} }
-- A site is live while the handshake on its tunnel wg_c<concentrator> is
-- younger than 180 s (the same rule as noderoute).
--
-- What it does:
--   * puts the address6 of every site on br-client
--   * source routing: from <site /64> -> table of the site -> its tunnel
--   * RA per prefix, one uradvd per site (see /etc/init.d/gluon-radvd).
--     The effective primary is preferred, every other prefix is sent with
--     preferred lifetime 0. A dead site is sent for DEAD_KEEP s, then not.
--   * rejects packets from a dead site's /64 with ICMPv6 code 5
--   * the IPv4 default route follows the effective primary
--   * one CLAT per tunnel, each with the xlat /64 of its own site

local json = require("jsonc")

local TMPDIR = "/tmp/ff-Ohb0ba0u"
local CONF = TMPDIR .. "/noderoute.json"
local ROUTE4_FILE = TMPDIR .. "/noderoute-route4"
local STATE = "/tmp/parker-as"
local CLIENT_IF = "br-client"
local LIVE_AGE = 180
local DEAD_KEEP = 180
local PREFERRED = 120
local VALID = 180
local TABLE_BASE = 100
local NAT64_PREFIX = "64:ff9b::/96"

local function read(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local s = f:read("*a")
  f:close()
  return s
end

local function write(path, data)
  local f = assert(io.open(path, "w"))
  f:write(data)
  f:close()
end

-- Write only when the content changes. Returns true on a change.
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

local function handshake_age(iface)
  local out = output("wg show " .. iface .. " latest-handshakes")
  local ts = tonumber(out:match("(%d+)%s*$") or "")
  if not ts or ts == 0 then return nil end
  return os.time() - ts
end

-- The stock uradvd arguments without the options we set per prefix, and
-- the prefix flag the stock arguments use (-a or -p).
local function stock_radvd_args()
  local out = output("/lib/gluon/radvd/arguments")
  local skip = { ["-a"] = true, ["-p"] = true, ["--rdnss"] = true, ["-i"] = true,
    ["--preferred-lifetime"] = true, ["--valid-lifetime"] = true }
  local result, drop, flag = {}, false, "-a"
  for tok in out:gmatch("%S+") do
    if drop then
      drop = false
    elseif skip[tok] then
      drop = true
      if tok == "-a" or tok == "-p" then flag = tok end
    else
      table.insert(result, tok)
    end
  end
  return table.concat(result, " "), flag
end

local function find_concentrator(conf, id)
  for _, conc in ipairs(conf.concentrators or {}) do
    if tostring(conc.id) == tostring(id) then return conc end
  end
  return nil
end

local function main()
  sh("mkdir -p " .. STATE)
  local raw = read(CONF)
  local conf = raw and json.parse(raw)
  if not conf or type(conf.sites) ~= "table" or not conf.primary_site then
    write(STATE .. "/status", "no multipop config\n")
    return
  end

  local names = {}
  for name in pairs(conf.sites) do table.insert(names, name) end
  table.sort(names)

  local now = os.time()
  local live, iface, tbl = {}, {}, {}
  for i, name in ipairs(names) do
    local site = conf.sites[name]
    tbl[name] = TABLE_BASE + i
    live[name] = false
    if site.concentrator then
      iface[name] = "wg_c" .. tostring(site.concentrator)
      local age = handshake_age(iface[name])
      live[name] = age ~= nil and age < LIVE_AGE
    end
    local dead_file = STATE .. "/dead." .. name
    if live[name] then
      os.remove(dead_file)
    elseif not read(dead_file) then
      write(dead_file, tostring(now))
      log("site " .. name .. " is dead")
    end
  end

  -- The configured primary while it is live, else the first live site.
  local effective = nil
  if live[conf.primary_site] then
    effective = conf.primary_site
  else
    for _, name in ipairs(names) do
      if live[name] then effective = name break end
    end
  end

  -- Addresses and source routing. The rules stay in place all the time.
  -- Packets from a dead site's prefix are rejected below, before they leave.
  local rules = output("ip -6 rule show")
  for _, name in ipairs(names) do
    local site = conf.sites[name]
    sh("ip -6 addr replace " .. site.address6 .. "/64 dev " .. CLIENT_IF)
    if not rules:find("to " .. site.range6 .. " lookup main", 1, true) then
      sh("ip -6 rule add to " .. site.range6 .. " lookup main prio 80")
    end
    for _, src in ipairs({ site.range6, site.xlat_range6 }) do
      if src and not rules:find("from " .. src .. " lookup " .. tbl[name], 1, true) then
        sh("ip -6 rule add from " .. src .. " lookup " .. tbl[name] .. " prio 100")
      end
    end
    if iface[name] then
      sh("ip -6 route replace default dev " .. iface[name] .. " table " .. tbl[name])
    end
  end

  -- ICMPv6 destination unreachable, code 5 (source address failed
  -- ingress/egress policy) for packets from a dead site's prefix.
  local dead = {}
  for _, name in ipairs(names) do
    if not live[name] then table.insert(dead, conf.sites[name].range6) end
  end
  -- Gluon uses firewall3 (iptables), so the rules go in an ip6tables chain.
  -- Compare with the kernel each time: a firewall reload removes the chain.
  local want = "-N parker_as\n"
  for _, src in ipairs(dead) do
    want = want .. "-A parker_as -s " .. src .. " -j REJECT --reject-with icmp6-policy-fail\n"
  end
  if output("ip6tables -S parker_as") ~= want then
    sh("ip6tables -N parker_as")
    sh("ip6tables -F parker_as")
    for _, src in ipairs(dead) do
      if not sh("ip6tables -A parker_as -s " .. src .. " -j REJECT --reject-with icmp6-policy-fail") then
        log("ip6tables reject failed for " .. src)
      end
    end
  end
  if not sh("ip6tables -C FORWARD -j parker_as") then
    sh("ip6tables -I FORWARD 1 -j parker_as")
  end

  -- RA: one file per site with the uradvd arguments.
  local stock, prefix_flag = stock_radvd_args()
  local radvd_changed = false
  for _, name in ipairs(names) do
    local site = conf.sites[name]
    local path = STATE .. "/radvd." .. name
    local dead_since = tonumber(read(STATE .. "/dead." .. name) or "")
    local args = nil
    if effective ~= nil and (live[name] or (dead_since and now - dead_since < DEAD_KEEP)) then
      local preferred = (name == effective) and PREFERRED or 0
      args = "-i " .. CLIENT_IF .. " " .. prefix_flag .. " " .. site.range6
        .. " --preferred-lifetime " .. preferred .. " --valid-lifetime " .. VALID
      if site.dns64 then args = args .. " --rdnss " .. site.dns64 end
      if stock ~= "" then args = args .. " " .. stock end
      if not stock:find("--pref64", 1, true) then
        args = args .. " --pref64 " .. NAT64_PREFIX
      end
    end
    if args then
      radvd_changed = update_file(path, args .. "\n") or radvd_changed
    elseif read(path) then
      os.remove(path)
      radvd_changed = true
    end
  end
  if radvd_changed then
    sh("/etc/init.d/gluon-radvd restart")
    log("RA changed, effective primary " .. tostring(effective))
  end

  -- CLAT: each tunnel translates into the xlat /64 of its own site.
  local clat_changed = false
  for _, name in ipairs(names) do
    local xlat = conf.sites[name].xlat_range6
    if iface[name] and xlat then
      clat_changed = update_file("/tmp/xlat_range6." .. iface[name], xlat) or clat_changed
    end
  end
  if clat_changed then
    sh("/etc/init.d/ebpf-clat restart")
  end

  -- IPv4 and IPv6 default routes on the effective primary tunnel. Keep the
  -- MTU and the record of noderoute, so noderoute takes the route as its own.
  if effective and iface[effective] then
    local conc = find_concentrator(conf, conf.sites[effective].concentrator)
    local route4 = read(ROUTE4_FILE)
    if conc and route4 and not route4:find("dev " .. iface[effective] .. " ", 1, true) then
      local new = "default via " .. conc.address4 .. " dev " .. iface[effective] .. " proto 23"
      local mtu = route4:match("mtu (%d+)")
      if mtu then new = new .. " mtu " .. mtu end
      if sh("ip -4 route replace " .. new) then
        write(ROUTE4_FILE, new)
        sh("ip -6 route replace default via " .. conc.address6 .. " dev " .. iface[effective] .. " proto 23")
        log("IPv4 default moved to " .. iface[effective])
      end
    end
  end

  local status = { "primary_site=" .. conf.primary_site, "effective=" .. tostring(effective) }
  for _, name in ipairs(names) do
    table.insert(status, "site " .. name .. " " .. (live[name] and "live" or "dead")
      .. " iface=" .. tostring(iface[name]) .. " range6=" .. conf.sites[name].range6
      .. " ra=" .. (read(STATE .. "/radvd." .. name) and "on" or "off"))
  end
  write(STATE .. "/status", table.concat(status, "\n") .. "\n")
end

main()
