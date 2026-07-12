-- SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
--[[ ============================================================================
  patches/demod-pitch-runner/songs.lua — content catalogue (pure data).

  DRILLS are generated on the fly (scale-constrained to the chosen instrument);
  RIFFS are short authored single-note melodies (concert-pitch MIDI), transposed
  into the instrument's range by main. No dm.* — plain data.

  © 2026 DeMoD LLC. Private.
============================================================================ ]]
local function seq(pitches, step, dur)
	step = step or 1
	local out = {}
	for i, p in ipairs(pitches) do
		out[#out + 1] = { beat = (i - 1) * step, note = p, dur = dur or 0 }
	end
	return out
end

return {
	drills = {
		{ id = "cmaj", name = "Major Scale", scale_id = "major", bars = 8, density = 0.9 },
		{ id = "penta", name = "Pentatonic Roam", scale_id = "pentatonic", bars = 8, density = 0.75 },
		{ id = "blues", name = "Blues Lines", scale_id = "blues", bars = 8, density = 0.7 },
		{ id = "minor", name = "Minor Scale", scale_id = "minor", bars = 8, density = 0.85 },
	},
	riffs = {
		-- "Ode to Joy" (Beethoven) — public domain
		{ id = "ode", name = "Ode to Joy", notes = seq({ 64, 64, 65, 67, 67, 65, 64, 62, 60, 60, 62, 64, 64, 62, 62 }) },
		-- "Twinkle Twinkle" — public domain
		{ id = "twinkle", name = "Twinkle Star", notes = seq({ 60, 60, 67, 67, 69, 69, 67, 65, 65, 64, 64, 62, 62, 60 }) },
	},
}
