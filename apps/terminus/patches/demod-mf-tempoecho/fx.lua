-- SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
--[[ ============================================================================
  patches/demod-mf-tempoecho/fx.lua -- fx descriptor for TempoEcho (see 19_TempoEcho.dsp), part of the
  Metal Forge suite.
  Params 0..6 match the widget declaration order in the .dsp.

  (c) 2026 DeMoD LLC. Private.
============================================================================ ]]
local HERE = (debug.getinfo(1, "S").source:gsub("^@", "")):match("(.*)/[^/]*$") or "."

return {
	v = 1,
	name = "TEMPOECHO",
	kind = "fx",
	path = HERE .. "/19_TempoEcho.so", -- compiled Faust artifact (device-side)
	slot = 3,
	params = {
		{ label = "BPM", min = 40, max = 240, init = 120, step = 0.1 },
		{ label = "Div L", min = 1, max = 16, init = 4, step = 1 },
		{ label = "Div R", min = 1, max = 16, init = 6, step = 1 },
		{ label = "Feedback", min = 0, max = 0.97, init = 0.5, step = 0.01 },
		{ label = "Tone", min = 500, max = 12000, init = 4000, step = 1, unit = "Hz" },
		{ label = "Mix", min = 0, max = 1, init = 0.4, step = 0.01 },
		{ label = "Gain", min = -12, max = 6, init = 0, step = 0.1, unit = "dB" },
	},
}
