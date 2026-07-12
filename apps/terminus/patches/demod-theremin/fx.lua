-- SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
--[[ ============================================================================
  patches/demod-theremin/fx.lua -- descriptor for THEREMIN (see demod_theremin.dsp). New DeMoD voice;
  params match the COMPILED Faust control bus order (tools/sync_params.py).
  (c) 2026 DeMoD LLC. Private.
============================================================================ ]]
local HERE = (debug.getinfo(1, "S").source:gsub("^@", "")):match("(.*)/[^/]*$") or "."

return {
	v = 1,
	name = "THEREMIN",
	kind = "synth",
	path = HERE .. "/demod_theremin.so", -- compiled Faust artifact (device-side)
	slot = 1,
	params = {
		{ label = "Glide", min = 0, max = 0.5, init = 0.08, step = 0.001, unit = "s" },
		{ label = "Vib Rate", min = 0, max = 9, init = 5.5, step = 0.01, unit = "Hz" },
		{ label = "Vib Depth", min = 0, max = 1, init = 0.4, step = 0.01 },
		{ label = "Warmth", min = 0, max = 1, init = 0.2, step = 0.01 },
		{ label = "Attack", min = 0.005, max = 1, init = 0.06, step = 0.001, unit = "s" },
		{ label = "Level", min = 0, max = 1, init = 0.7, step = 0.01 },
		{ label = "freq", min = 20, max = 8000, init = 440, step = 0.01, unit = "Hz" },
		{ label = "gain", min = 0, max = 1, init = 0.8, step = 0.01 },
		{ label = "gate", min = 0, max = 1, init = 0, step = 1 },
	},
}
