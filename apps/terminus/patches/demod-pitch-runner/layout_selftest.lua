-- SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
--[[ ============================================================================
  patches/demod-pitch-runner/layout_selftest.lua — assert the layout never
  overlaps or overflows across a matrix of screen sizes. No display:

      ~/demod-ui/demod-ui patches/demod-pitch-runner/layout_selftest.lua
============================================================================ ]]
local HERE = (debug.getinfo(1, "S").source:gsub("^@", "")):match("(.*/)") or "./"
local LAY = dofile(HERE .. "layout.lua")

local fails = 0
local function check(cond, msg)
	if not cond then
		io.stderr:write("FAIL: " .. msg .. "\n")
		fails = fails + 1
	end
end

local sizes = {
	{ 320, 240 },
	{ 400, 300 },
	{ 480, 320 },
	{ 640, 480 },
	{ 800, 480 },
	{ 1024, 600 },
	{ 1280, 720 },
	{ 1920, 1080 },
}
local lane_counts = { 4, 5, 6 } -- bass / keys / guitar

local function within(z, W, H)
	return z.x >= 0 and z.y >= 0 and (z.x + z.w) <= W and (z.y + z.h) <= H
end

for _, s in ipairs(sizes) do
	local W, H = s[1], s[2]
	for _, lanes in ipairs(lane_counts) do
		local tag = W .. "x" .. H .. " lanes=" .. lanes
		local L = LAY.compute(W, H, lanes)

		-- vertical ordering, non-overlapping, on-screen
		local order = { L.header, L.info, L.play, L.tv, L.foot }
		local prev_bottom = 0
		for i, z in ipairs(order) do
			check(z.y >= prev_bottom - 1, tag .. ": zone " .. i .. " starts below previous (no overlap)")
			prev_bottom = z.y + z.h
		end
		check(prev_bottom <= H + 1, tag .. ": last zone fits within H")

		-- panels on-screen and within horizontal padding
		check(within(L.play, W, H), tag .. ": play panel on-screen")
		check(within(L.tv, W, H), tag .. ": target panel on-screen")
		check(L.play.x >= L.pad - 1 and (L.play.x + L.play.w) <= W - L.pad + 1, tag .. ": play within pad")

		-- highway interior inside the play panel
		local hw = L.hw
		check(hw.x >= L.play.x and (hw.x + hw.w) <= L.play.x + L.play.w + 1, tag .. ": highway x inside play")
		check(hw.y >= L.play.y and hw.hitY <= L.play.y + L.play.h, tag .. ": hit-line inside play panel")
		check(hw.laneW > 4, tag .. ": lanes wide enough to be legible (>4px)")

		-- foot never clipped
		check((L.foot.y + L.foot.h) <= H, tag .. ": footer not clipped")
		check(L.info.best_x > L.info.score_x, tag .. ": info columns ordered")

		-- centred card stays on-screen
		local c = LAY.card(W, H, 0.8, 0.7)
		check(within(c, W, H), tag .. ": card on-screen")
	end
end

if fails == 0 then
	print("layout selftest: ALL PASS (" .. (#sizes * #lane_counts) .. " size/lane combos)")
	os.exit(0)
else
	io.stderr:write("layout selftest: " .. fails .. " FAILED\n")
	os.exit(1)
end
