-- SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
--[[ ============================================================================
  patches/demod-metronome/fx.lua -- fx descriptor for METRONOME (see demod_metronome.dsp).
  Params match the COMPILED Faust control bus order (tools/sync_params.py).
  (c) 2026 DeMoD LLC. Private.
============================================================================ ]]
local HERE = (debug.getinfo(1, "S").source:gsub("^@", "")):match("(.*)/[^/]*$") or "."

return {
	v = 1,
	name = "METRONOME",
	kind = "synth",
	path = HERE .. "/demod_metronome.so", -- compiled Faust artifact (device-side)
	slot = 1,
	params = {
		{ label = "BPM", min = 40, max = 240, init = 120, step = 1 },
		{ label = "Beats", min = 1, max = 8, init = 4, step = 1 },
		{ label = "Click", min = 400, max = 3000, init = 1000, step = 1, unit = "Hz" },
		{ label = "Accent", min = 0, max = 1, init = 0.7, step = 0.01 },
		{ label = "Level", min = 0, max = 1, init = 0.6, step = 0.01 },
	},
}
