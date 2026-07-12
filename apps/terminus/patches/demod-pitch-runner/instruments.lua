-- SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
--[[ ============================================================================
  patches/demod-pitch-runner/instruments.lua — instrument profiles + fret math.

  PURE Lua (no dm.*, no global state) so it unit-tests under the interpreter
  (see selftest.lua). "Learn any instrument" works because hits are graded on
  PITCH, which is instrument-agnostic; a profile only describes the playable
  range and — for string instruments — how a pitch maps to a string + fret so
  the on-screen fretboard can show WHERE to play it.

  Tunings are MIDI note numbers, low string first. MIDI 69 = A4 = 440 Hz.

  © 2026 DeMoD LLC. Private.
============================================================================ ]]
local floor, min, max = math.floor, math.min, math.max

local M = {}

M.PROFILES = {
	{ id = "guitar", name = "Guitar", kind = "fret", tuning = { 40, 45, 50, 55, 59, 64 }, frets = 15 }, -- E2 A2 D3 G3 B3 E4
	{ id = "bass", name = "Bass", kind = "fret", tuning = { 28, 33, 38, 43 }, frets = 15 }, -- E1 A1 D2 G2
	{ id = "ukulele", name = "Ukulele", kind = "fret", tuning = { 67, 60, 64, 69 }, frets = 12 }, -- G4 C4 E4 A4 (reentrant)
	{ id = "violin", name = "Violin", kind = "fret", tuning = { 55, 62, 69, 76 }, frets = 12 }, -- G3 D4 A4 E5
	{ id = "piano", name = "Piano", kind = "keys", low = 48, high = 84 }, -- C3..C6
	{ id = "voice", name = "Voice", kind = "keys", low = 48, high = 72, octave_ok = true }, -- C3..C5
	{ id = "flute", name = "Flute/Wind", kind = "keys", low = 60, high = 84 }, -- C4..C6
}

local KEY_BANDS = 5 -- register columns for keyboard instruments

function M.by_id(id)
	for _, p in ipairs(M.PROFILES) do
		if p.id == id then
			return p
		end
	end
	return M.PROFILES[1]
end

-- lowest playable string+fret for a pitch (smallest fret wins), or nil if off-board
function M.note_to_fret(prof, midi)
	if prof.kind ~= "fret" then
		return nil
	end
	local best = nil
	for i, open in ipairs(prof.tuning) do
		local fret = midi - open
		if fret >= 0 and fret <= prof.frets then
			if best == nil or fret < best.fret then
				best = { string = i, fret = fret }
			end
		end
	end
	return best
end

-- min..max MIDI the instrument can produce
function M.range(prof)
	if prof.kind == "fret" then
		local lo, hi = 1e9, -1e9
		for _, open in ipairs(prof.tuning) do
			lo = min(lo, open)
			hi = max(hi, open + prof.frets)
		end
		return lo, hi
	end
	return prof.low, prof.high
end

function M.playable(prof, midi)
	if prof.kind == "fret" then
		return M.note_to_fret(prof, midi) ~= nil
	end
	return midi >= prof.low and midi <= prof.high
end

-- number of highway lanes: one per string, or a fixed set of register bands
function M.lanes(prof)
	if prof.kind == "fret" then
		return #prof.tuning
	end
	return KEY_BANDS
end

-- register band 0..KEY_BANDS-1 for a keyboard pitch
function M.band(prof, midi)
	local lo, hi = M.range(prof)
	local n = M.lanes(prof)
	if hi <= lo then
		return 0
	end
	local b = floor((midi - lo) / ((hi - lo) / n))
	return max(0, min(n - 1, b))
end

-- which highway lane a pitch belongs to (string index, or register band)
function M.lane(prof, midi)
	if prof.kind == "fret" then
		local f = M.note_to_fret(prof, midi)
		return f and (f.string - 1) or 0
	end
	return M.band(prof, midi)
end

return M
