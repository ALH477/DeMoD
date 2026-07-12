-- SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
--[[ ============================================================================
  patches/demod-looper/fx.lua — fx descriptor for the looper (see looper.dsp).
  DSP Studio reads this (DEMOD_DSP_PATCH) and calls dsp.load_patch(slot, spec);
  the engine dlopens the compiled looper.so. Params 0..5 match looper.dsp.
  © 2026 DeMoD LLC. Private.
============================================================================ ]]
local HERE = (debug.getinfo(1, "S").source:gsub("^@", "")):match("(.*)/[^/]*$") or "."

return {
	v = 1,
	name = "LOOPER",
	kind = "fx",
	path = HERE .. "/looper.so", -- compiled Faust artifact (device-side)
	slot = 1,
	params = {
		{ label = "RECORD", min = 0, max = 1, init = 0, step = 1 },
		{ label = "OVERDUB", min = 0, max = 1, init = 0, step = 1 },
		{ label = "PLAY", min = 0, max = 1, init = 1, step = 1 },
		{ label = "CLEAR", min = 0, max = 1, init = 0, step = 1 },
		{ label = "LEVEL", min = 0, max = 1, init = 1.0, step = 0.01, unit = "%" },
		{ label = "LOOP", min = 100, max = 8000, init = 1000, step = 1, unit = "ms" },
	},
}
