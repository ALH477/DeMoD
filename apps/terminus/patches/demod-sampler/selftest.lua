-- SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
--[[ ============================================================================
  patches/demod-sampler/selftest.lua — pad-model asserts (pure, no display).
      ~/demod-ui/demod-ui patches/demod-sampler/selftest.lua
============================================================================ ]]
local HERE = (debug.getinfo(1, "S").source:gsub("^@", "")):match("(.*/)") or "./"
local Pads = dofile(HERE .. "pads.lua")

local fails = 0
local function check(c, m)
	if not c then
		io.stderr:write("FAIL: " .. m .. "\n")
		fails = fails + 1
	end
end

do
	local p = Pads.new(16)
	check(p.n == 16 and p:assigned_count() == 0, "fresh bank empty")
	p:assign(3, "smpABC", "Kick")
	check(p:get(3).id == "smpABC" and p:get(3).name == "Kick", "assign")
	check(p:assigned_count() == 1, "one assigned")
	p:set_gain(3, 0.7)
	check(math.abs(p:get(3).gain - 0.7) < 1e-9, "set gain")
	p:bump_gain(3, 0.5)
	check(math.abs(p:get(3).gain - 1.2) < 1e-9, "bump gain")
	p:bump_gain(3, 5)
	check(math.abs(p:get(3).gain - 1.5) < 1e-9, "gain clamps to 1.5")
	p:assign(16, "smpZ", "Crash")
	p:clear(3)
	check(p:get(3).id == nil and p:assigned_count() == 1, "clear")
end

do -- serialize round-trip
	local p = Pads.new(16)
	p:assign(1, "id1", "Kick 1")
	p:set_gain(1, 0.8)
	p:assign(7, "id7", "Snare")
	p:assign(16, "id16", "Hat")
	local q = Pads.new(16):deserialize(p:serialize())
	check(q:get(1).id == "id1" and q:get(1).name == "Kick 1" and math.abs(q:get(1).gain - 0.8) < 1e-3, "pad 1 round-trips")
	check(q:get(7).id == "id7" and q:get(16).id == "id16", "pads 7 + 16 round-trip")
	check(q:assigned_count() == 3, "count round-trips")
end

do -- prune drops pads whose sample id is gone
	local p = Pads.new(16)
	p:assign(2, "live", "A")
	p:assign(5, "dead", "B")
	p:prune({ live = true })
	check(p:get(2).id == "live" and p:get(5).id == nil, "prune removes missing ids")
end

if fails == 0 then
	print("sampler-pads selftest: ALL PASS")
	os.exit(0)
else
	io.stderr:write("sampler-pads selftest: " .. fails .. " FAILED\n")
	os.exit(1)
end
