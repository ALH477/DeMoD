-- SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
--[[ ============================================================================
  patches/demod-learn/selftest.lua — headless asserts for theory.lua.
  Pure Lua, no dm.* / no display:

      lua patches/demod-learn/selftest.lua

  Exits non-zero on the first failed assertion.
============================================================================ ]]
local HERE = (debug.getinfo(1, "S").source:gsub("^@", "")):match("(.*/)") or "./"
local T = dofile(HERE .. "theory.lua")

local fails = 0
local function check(cond, msg)
	if not cond then
		io.stderr:write("FAIL: " .. msg .. "\n")
		fails = fails + 1
	end
end
local function approx(a, b, eps)
	return math.abs(a - b) <= (eps or 1e-6)
end

-- note names: A4 = MIDI 69, middle C = 60
check(T.midi_to_name(69) == "A4", "midi_to_name(69) == A4")
check(T.midi_to_name(60) == "C4", "midi_to_name(60) == C4")
check(T.midi_to_name(61) == "C#4", "midi_to_name(61) == C#4")

-- frequencies
check(approx(T.midi_to_freq(69), 440, 1e-9), "midi_to_freq(69) == 440")
check(approx(T.midi_to_freq(57), 220, 1e-6), "midi_to_freq(57) == 220 (A3)")
check(approx(T.midi_to_freq(81), 880, 1e-6), "midi_to_freq(81) == 880 (A5)")

-- scales
check(#T.SCALES[1].steps == 7, "major scale has 7 degrees")
check(T.SCALES[1].steps[3] == 4, "major 3rd degree is +4 semitones")
check(#T.scale_notes(60, T.SCALES[1], 1) == 8, "one-octave major scale incl top root = 8 notes")

-- cents
do
	local n, c = T.cents_off(440)
	check(n == 69 and approx(c, 0, 1e-6), "cents_off(440) -> A4, 0 cents")
end

-- intervals
check(T.INTERVALS[1].semi == 0, "first interval is unison")

-- phrase determinism + bounds
do
	local a = T.phrase(42, 4, T.SCALES[1], 60)
	local b = T.phrase(42, 4, T.SCALES[1], 60)
	check(#a == 4, "phrase length honoured")
	local same = true
	for i = 1, #a do
		if a[i] ~= b[i] then
			same = false
		end
	end
	check(same, "phrase is deterministic for a fixed seed")
	local c = T.phrase(43, 4, T.SCALES[1], 60)
	local diff = false
	for i = 1, #a do
		if a[i] ~= c[i] then
			diff = true
		end
	end
	check(diff, "different seed yields a different phrase")
	-- all notes in range [root, root+12]
	for _, n in ipairs(a) do
		check(n >= 60 and n <= 72, "phrase note in one-octave range")
	end
end

if fails == 0 then
	print("theory.lua selftest: ALL PASS")
	os.exit(0)
else
	io.stderr:write("theory.lua selftest: " .. fails .. " FAILED\n")
	os.exit(1)
end
