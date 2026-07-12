-- SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
--[[ ============================================================================
  midi/map.lua — the ONE place note numbers become musical meaning (pure, dm-free).

  Before this module every consumer rolled its own mapping: the drum machine had a
  GM→voice table, the sampler did `pad = d1 - 35` (and ignored velocity), the synth
  path inlined `440 * 2^((n-69)/12)`. This is the shared source of truth so they all
  agree. No dm.*; safe to unit-test and to dofile from anywhere.

  © 2026 DeMoD LLC. Private.
============================================================================ ]]

local M = {}

-- General-MIDI percussion note → an 8-voice drum index (1..8), folding the common
-- GM drum map (35–59) onto KICK/SNARE/CLAP/CHAT/OHAT/TOM/COWBELL/CRASH so an
-- off-the-shelf pad controller or a .mid drum track lands sensibly. This is the
-- canonical table; patches/demod-drum-machine/voices.lua delegates here.
M.GM = {
	[35] = 1,
	[36] = 1, -- kicks → KICK
	[37] = 2,
	[38] = 2,
	[40] = 2, -- side stick / snares → SNARE
	[39] = 3, -- hand clap → CLAP
	[42] = 4,
	[44] = 4, -- closed / pedal hat → CLOSED HAT
	[46] = 5, -- open hat → OPEN HAT
	[41] = 6,
	[43] = 6,
	[45] = 6,
	[47] = 6,
	[48] = 6,
	[50] = 6, -- toms → TOM
	[56] = 7,
	[54] = 7, -- cowbell / tambourine → COWBELL
	[49] = 8,
	[51] = 8,
	[52] = 8,
	[53] = 8,
	[55] = 8,
	[57] = 8,
	[59] = 8, -- cymbals → CRASH
}

-- 8-voice drum index for a GM note (nil if unmapped).
function M.gm_to_voice(note)
	return M.GM[note]
end

-- Note → 1-based pad index for an `npads`-pad grid starting at `base` (GM kick 36
-- by default). Returns nil when out of range. Replaces the sampler's bare d1-35.
function M.note_to_pad(note, npads, base)
	base = base or 36
	local pad = (note - base) + 1
	if pad >= 1 and pad <= (npads or 16) then
		return pad
	end
	return nil
end

-- Equal-tempered frequency (Hz) for a MIDI note (A4=69=440Hz).
function M.note_to_hz(note)
	return 440.0 * 2 ^ ((note - 69) / 12)
end

local NAMES = { "C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B" }

-- "C4", "F#3", … for a MIDI note (middle C = 60 = C4).
function M.note_name(note)
	note = math.floor(note + 0.5)
	local n = (note % 12) + 1
	local oct = math.floor(note / 12) - 1
	return NAMES[n] .. tostring(oct)
end

-- Normalize a raw 0..127 velocity into 0..1 per the chosen policy.
--   mode "fixed"     → always `fixed` (default 0.8)
--   mode "as_played" → raw / 127 (default)
function M.velocity(raw, mode, fixed)
	if mode == "fixed" then
		return fixed or 0.8
	end
	return (raw or 0) / 127
end

return M
