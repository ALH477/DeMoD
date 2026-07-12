-- SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
--[[ ============================================================================
  dsp/fx_descriptors.lua — stock effect parameter metadata.

  Mirrors the hslider declarations in demod5 dsp/effects/*.dsp so the
  orchestrator backend (which has no parameter introspection over the control
  socket yet) can render correct labels/ranges. Index matches the Faust "[n]"
  order, which is the `idx` used by set_param.

  Each entry: { label, min, max, init, step, unit }
  Copyright (c) 2026 DeMoD LLC. All rights reserved. Private — not for public distribution.
============================================================================ ]]

local function p(label, min, max, init, step, unit)
	return { label = label, min = min, max = max, init = init, step = step, unit = unit or "" }
end

local EFFECTS = {
	OVERDRIVE = {
		p("DRIVE", 1.0, 20.0, 5.0, 0.1, "x"),
		p("TONE", 0.0, 1.0, 0.5, 0.01, "%"),
		p("OUTPUT", 0.0, 1.0, 0.5, 0.01, "%"),
		p("MIX", 0.0, 1.0, 1.0, 0.01, "%"),
	},
	CHORUS = {
		p("RATE", 0.01, 5.0, 0.8, 0.01, "Hz"),
		p("DEPTH", 0.1, 10.0, 3.0, 0.1, "ms"),
		p("MIX", 0.0, 1.0, 0.5, 0.01, "%"),
		p("STEREO", 0.0, 1.0, 0.5, 0.01, "%"),
	},
	DELAY = {
		p("TIME", 10, 2000, 250, 1, "ms"),
		p("FEEDBACK", 0.0, 0.95, 0.4, 0.01, "%"),
		p("MIX", 0.0, 1.0, 0.3, 0.01, "%"),
		p("HI-CUT", 200, 20000, 8000, 1, "Hz"),
		p("MOD DEPTH", 0.0, 5.0, 0.0, 0.01, ""),
		p("MOD RATE", 0.01, 5.0, 0.5, 0.01, "Hz"),
	},
	REVERB = {
		p("ROOM SIZE", 0.0, 1.0, 0.5, 0.01, "%"),
		p("DAMPING", 0.0, 1.0, 0.5, 0.01, "%"),
		p("MIX", 0.0, 1.0, 0.3, 0.01, "%"),
		p("PRE-DELAY", 0.0, 0.1, 0.02, 0.001, ""),
	},
	COMPRESS = {
		p("THRESHOLD", -60.0, 0.0, -20.0, 0.1, "dB"),
		p("RATIO", 1.0, 20.0, 4.0, 0.1, "x"),
		p("ATTACK", 0.1, 100.0, 5.0, 0.1, "ms"),
		p("RELEASE", 10.0, 1000.0, 100.0, 1.0, "ms"),
		p("MAKEUP", 0.0, 30.0, 0.0, 0.1, "dB"),
		p("MIX", 0.0, 1.0, 1.0, 0.01, "%"),
	},
	EQ = {
		p("LOW GAIN", -12.0, 12.0, 0.0, 0.1, "dB"),
		p("LOW FREQ", 20.0, 1000.0, 200.0, 1, "Hz"),
		p("MID GAIN", -12.0, 12.0, 0.0, 0.1, "dB"),
		p("MID FREQ", 100.0, 10000.0, 1000.0, 1, "Hz"),
		p("MID Q", 0.1, 10.0, 1.0, 0.01, "x"),
		p("HIGH GAIN", -12.0, 12.0, 0.0, 0.1, "dB"),
		p("HIGH FREQ", 1000.0, 20000.0, 4000.0, 1, "Hz"),
	},
	FLANGER = {
		p("RATE", 0.01, 5.0, 0.3, 0.01, "Hz"),
		p("DEPTH", 0.0, 1.0, 0.7, 0.01, "%"),
		p("FEEDBACK", -0.95, 0.95, 0.5, 0.01, "%"),
		p("MIX", 0.0, 1.0, 0.5, 0.01, "%"),
	},
	TREMOLO = {
		p("RATE", 0.1, 15.0, 4.0, 0.01, "Hz"),
		p("DEPTH", 0.0, 1.0, 0.5, 0.01, "%"),
	},
	-- Instrument (synth) — params 0/1/2 are gate/freq/level, the layout the MIDI
	-- player drives (dsp/midi_modes.lua). Loaded as kind="synth".
	SYNTH = {
		p("GATE", 0.0, 1.0, 0.0, 1.0, ""),
		p("FREQ", 20.0, 4000.0, 220.0, 1.0, "Hz"),
		p("LEVEL", 0.0, 1.0, 0.7, 0.01, "%"),
		p("CUTOFF", 50.0, 12000.0, 2000.0, 1.0, "Hz"),
	},
}

-- Per-effect metadata for the picker/browser (category + one-line description).
-- Kept separate so the EFFECTS arrays stay pure param lists.
local META = {
	OVERDRIVE = { category = "Drive", desc = "Pade-tanh saturation, drive + tone." },
	CHORUS = { category = "Modulation", desc = "Detuned modulated voices for width." },
	DELAY = { category = "Time", desc = "Echo with feedback, hi-cut + modulation." },
	REVERB = { category = "Space", desc = "Room/hall tail. Starts at 30% mix." },
	COMPRESS = { category = "Dynamics", desc = "Threshold/ratio compressor + makeup." },
	EQ = { category = "Filter", desc = "3-band EQ. Starts flat (0 dB); boost to hear it." },
	FLANGER = { category = "Modulation", desc = "Swept short delay with feedback (jet)." },
	TREMOLO = { category = "Modulation", desc = "Amplitude modulation (rate + depth)." },
	SYNTH = { category = "Synth", kind = "synth", desc = "Instrument voice driven by MIDI / detected pitch." },
}

-- default device slot layout (matches demod5 demod_main.lua ordering)
local DEFAULT_LAYOUT = { "OVERDRIVE", "CHORUS", "DELAY", "REVERB", "COMPRESS" }

return { effects = EFFECTS, meta = META, default_layout = DEFAULT_LAYOUT }
