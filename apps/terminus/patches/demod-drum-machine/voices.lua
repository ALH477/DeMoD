-- SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
--[[ ============================================================================
  patches/demod-drum-machine/voices.lua — the drum-voice table (pure, dm-free).

  Each row of the sequencer is one drum voice. A voice carries:
    name  : full label
    short : 4-char grid-header tag (drawn in its accent)
    gate  : 0-based param index of the matching *Gate trigger in demod-drums'
            fx descriptor (patches/demod-drums/fx.lua). The kit path pulses
            set_param(slot, gate, 1) then ..,0 to fire the voice.
    note  : General-MIDI drum note used by the K.sound fallback path (no kit
            loaded) — see audio.lua.
    accent: K.COL token name (resolved against gamekit's palette by main).

  Gate indices verified against demod-drums/fx.lua param declaration order:
    Snare Gate=5, CHat Gate=8, OHat Gate=12, Clap Gate=16, Bell Gate=20,
    Tom Gate=25, Crash Gate=28, 808K Gate=31 (909K Gate=36 is the alt kick).

  Rows are ordered low→high like a 808 panel reads top→bottom; the default
  demo pattern is a readable 4-on-the-floor + offbeat hats groove.

  © 2026 DeMoD LLC. Private.
============================================================================ ]]

local V = {}

-- 8 MVP voices (top row first). `accent` is a gamekit COL token.
V.list = {
	{ name = "KICK", short = "KICK", gate = 31, note = 36, accent = "red" },
	{ name = "SNARE", short = "SNAR", gate = 5, note = 38, accent = "yellow" },
	{ name = "CLAP", short = "CLAP", gate = 16, note = 39, accent = "violet" },
	{ name = "CLOSED HAT", short = "C.HH", gate = 8, note = 42, accent = "turq" },
	{ name = "OPEN HAT", short = "O.HH", gate = 12, note = 46, accent = "green" },
	{ name = "TOM", short = "TOM", gate = 25, note = 45, accent = "white" },
	{ name = "COWBELL", short = "COWB", gate = 20, note = 56, accent = "yellow" },
	{ name = "CRASH", short = "CRSH", gate = 28, note = 49, accent = "turq" },
}

V.count = #V.list

-- demod-drums identity hints for slot discovery (audio.lua)
V.kit_name_match = "DRUM" -- slot.name upper() contains this
V.kit_min_params = 30 -- the real descriptor has 37 params; guard against tiny synths

-- General-MIDI percussion note → our voice index. The canonical GM→8-voice fold
-- now lives in the shared midi/map.lua (one source of truth across the drum
-- machine, sampler, and the SMF importer); we delegate to it. HERE-relative so it
-- resolves whether run from the repo or an installed patch tree.
local MAP = dofile((debug.getinfo(1, "S").source:gsub("^@", "")):match("(.*/)") .. "../../midi/map.lua")
V.GM = MAP.GM

-- voice index for a GM note (nil if unmapped)
function V.gm_to_voice(note)
	return MAP.gm_to_voice(note)
end

-- A default groove laid onto a fresh 16-step pattern (1-based step columns that
-- are ON). Returned as voice-index -> { step,... } so pattern.lua can stamp it.
function V.default_groove()
	return {
		[1] = { 1, 5, 9, 13 }, -- KICK : 4-on-the-floor
		[2] = { 5, 13 }, -- SNARE: backbeat
		[4] = { 1, 3, 5, 7, 9, 11, 13, 15 }, -- C.HH : straight 8ths
		[5] = { 3, 7, 11, 15 }, -- O.HH : offbeat accents
	}
end

return V
