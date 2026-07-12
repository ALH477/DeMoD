-- SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
--[[ ============================================================================
  patches/demod-learn/theory.lua — pure music theory for the LEARN patch.

  NO dm.* calls and no global state: this is plain Lua data + functions so it runs
  under `lua`/`busted` for unit tests (see selftest.lua). All pitch is MIDI-note
  based; A4 = MIDI 69 = 440 Hz (the same convention as dsp/midi_modes.lua).

  © 2026 DeMoD LLC. Private.
============================================================================ ]]
local floor = math.floor

local T = {}

-- pitch-class names (sharps); index 1..12 maps to semitone 0..11
T.NOTE_NAMES = { "C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B" }

-- MIDI note -> "A4" / "C#5". Octave numbering: MIDI 60 = C4 (middle C).
function T.midi_to_name(n)
	n = floor(n + 0.5)
	local pc = n % 12
	local oct = floor(n / 12) - 1
	return T.NOTE_NAMES[pc + 1] .. tostring(oct)
end

-- MIDI note -> frequency in Hz (equal temperament, A4 = 440).
function T.midi_to_freq(n)
	return 440 * 2 ^ ((n - 69) / 12)
end

-- whether a pitch-class (semitone offset from C) is a black key on a piano
function T.is_black(pc)
	pc = pc % 12
	return pc == 1 or pc == 3 or pc == 6 or pc == 8 or pc == 10
end

-- scale = ascending semitone offsets from the root (one octave, root included)
T.SCALES = {
	{ id = "major", name = "Major", steps = { 0, 2, 4, 5, 7, 9, 11 } },
	{ id = "minor", name = "Natural Minor", steps = { 0, 2, 3, 5, 7, 8, 10 } },
	{ id = "pentatonic", name = "Major Pentatonic", steps = { 0, 2, 4, 7, 9 } },
	{ id = "blues", name = "Blues", steps = { 0, 3, 5, 6, 7, 10 } },
}

-- common intervals for the ear/interval drill (semitones from the root)
T.INTERVALS = {
	{ name = "Unison", semi = 0 },
	{ name = "Major 2nd", semi = 2 },
	{ name = "Major 3rd", semi = 4 },
	{ name = "Perfect 4th", semi = 5 },
	{ name = "Perfect 5th", semi = 7 },
	{ name = "Major 6th", semi = 9 },
	{ name = "Octave", semi = 12 },
}

-- expand a scale into absolute MIDI notes over `octaves`, starting at `root`.
function T.scale_notes(root, scale, octaves)
	octaves = octaves or 1
	local out = {}
	for o = 0, octaves - 1 do
		for _, s in ipairs(scale.steps) do
			out[#out + 1] = root + 12 * o + s
		end
	end
	out[#out + 1] = root + 12 * octaves -- top root, makes the octave audible
	return out
end

-- tiny deterministic LCG so phrases are reproducible from a seed (testable, and
-- the same seed always replays the same call-and-response phrase).
local function lcg(seed)
	local s = (floor(seed) % 2147483647)
	if s <= 0 then
		s = s + 2147483646
	end
	return function()
		s = (s * 16807) % 2147483647
		return s / 2147483647
	end
end

-- generate a melodic phrase of `len` notes drawn from `scale` rooted at `root`.
-- Deterministic for a given seed. Returns a list of MIDI note numbers.
function T.phrase(seed, len, scale, root)
	len = len or 4
	root = root or 60
	scale = scale or T.SCALES[1]
	local pool = T.scale_notes(root, scale, 1)
	local rnd = lcg(seed)
	local out = {}
	for _ = 1, len do
		out[#out + 1] = pool[1 + floor(rnd() * #pool)]
	end
	return out
end

-- cents a measured frequency is sharp(+)/flat(-) of the nearest equal-tempered note.
-- Returns nearest_midi, cents (cents in [-50, 50]).
function T.cents_off(freq)
	if not freq or freq <= 0 then
		return nil, 0
	end
	local midi = 69 + 12 * math.log(freq / 440) / math.log(2)
	local nearest = floor(midi + 0.5)
	return nearest, (midi - nearest) * 100
end

return T
