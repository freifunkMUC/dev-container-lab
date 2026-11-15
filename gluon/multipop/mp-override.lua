-- LAB PROTOTYPE - not production code.
--
-- nodeconfig.lua calls this function with the broker answer after the
-- signature check (hook added by gluon/launch.py). A multi-site answer has
-- a list of all pgws of each site. mp-node.sh can select another pgw of the
-- same site, also while the broker is down, and writes its public key to
-- /tmp/multipop/pgw.<id>. This function uses that pgw for the tunnel, else
-- the preferred one. Then nodeconfig does not change the peer back. The
-- changed answer goes back to the file, which nodeconfig copies to
-- noderoute.json.
local jsonc = require("jsonc")

local function chosen(id)
	local f = io.open("/tmp/multipop/pgw." .. tostring(id))
	if not f then
		return nil
	end
	local key = f:read("*l")
	f:close()
	return key
end

return function(t, path)
	local changed = false
	for _, c in ipairs(t.concentrators or {}) do
		if type(c.pgws) == "table" then
			local want, pick = chosen(c.id), nil
			for _, p in ipairs(c.pgws) do
				if p.pubkey == want then
					pick = p
				end
			end
			if not pick then
				for _, p in ipairs(c.pgws) do
					if p.preferred and not pick then
						pick = p
					end
				end
			end
			if pick then
				c.endpoint, c.pubkey, c.address6 = pick.endpoint, pick.pubkey, pick.address6
				changed = true
			end
		end
	end
	if changed and path then
		local f = io.open(path, "w")
		f:write(jsonc.stringify(t))
		f:close()
	end
	return t
end
