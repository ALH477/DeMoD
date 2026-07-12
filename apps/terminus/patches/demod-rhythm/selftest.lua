-- SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
--[[ ============================================================================
  patches/demod-rhythm/selftest.lua — headless asserts for chart.lua.
  Pure Lua, no dm.* / no display:

      ~/demod-ui/demod-ui patches/demod-rhythm/selftest.lua

  Exits non-zero if any assertion fails.
============================================================================ ]]
local HERE = (debug.getinfo(1, "S").source:gsub("^@", "")):match("(.*/)") or "./"
local C = dofile(HERE .. "chart.lua")

local fails = 0
local function check(cond, msg)
	if not cond then
		io.stderr:write("FAIL: " .. msg .. "\n")
		fails = fails + 1
	end
end

-- determinism: same seed -> identical chart
local a = C.generate(42, 8)
local b = C.generate(42, 8)
check(#a == #b and #a > 0, "same seed yields a chart of the same (nonzero) length")
do
	local same = #a == #b
	for i = 1, #a do
		if a[i].beat ~= b[i].beat or a[i].lane ~= b[i].lane or a[i].note ~= b[i].note then
			same = false
		end
	end
	check(same, "same seed is bit-for-bit deterministic")
end

-- a different seed yields a different chart
do
	local c = C.generate(43, 8)
	local diff = #a ~= #c
	for i = 1, math.min(#a, #c) do
		if a[i].lane ~= c[i].lane or a[i].note ~= c[i].note then
			diff = true
		end
	end
	check(diff, "different seed yields a different chart")
end

-- structural invariants: lanes in range, beats monotonic, notes in scale octaves
do
	local last = -1
	local ok_lane, ok_mono, ok_note = true, true, true
	for _, n in ipairs(a) do
		if n.lane < 0 or n.lane > C.LANES - 1 then
			ok_lane = false
		end
		if n.beat < last then
			ok_mono = false
		end
		last = n.beat
		if n.note < C.ROOT or n.note > C.ROOT + 12 * C.LANES then
			ok_note = false
		end
	end
	check(ok_lane, "all lanes within 0..LANES-1")
	check(ok_mono, "beats are monotonic non-decreasing")
	check(ok_note, "all notes within the root + lane-octave range")
end

-- judging windows (bpm = 120 => 1 beat = 0.5 s)
check(C.judge(0, 120) == "perfect", "exact hit is perfect")
check(C.judge(0.05, 120) == "perfect", "0.025 s error is perfect") -- 0.05 beat * 0.5 = 0.025 s
check(C.judge(0.15, 120) == "good", "0.075 s error is good") -- 0.15 beat * 0.5 = 0.075 s
check(C.judge(0.5, 120) == "miss", "0.25 s error is a miss")
check(C.judge(-0.05, 120) == "perfect", "judging is symmetric for early hits")

if fails == 0 then
	print("chart.lua selftest: ALL PASS (" .. #a .. " notes)")
	os.exit(0)
else
	io.stderr:write("chart.lua selftest: " .. fails .. " FAILED\n")
	os.exit(1)
end
