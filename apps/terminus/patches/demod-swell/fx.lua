-- SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
--[[ ============================================================================
  patches/demod-swell/fx.lua -- fx descriptor for SWELL (see demod_swell.dsp).
  Params match the COMPILED Faust control bus order (tools/sync_params.py).
  (c) 2026 DeMoD LLC. Private.
============================================================================ ]]
local HERE = (debug.getinfo(1, "S").source:gsub("^@", "")):match("(.*)/[^/]*$") or "."

return {
	v = 1,
	name = "SWELL",
	kind = "fx",
	path = HERE .. "/demod_swell.so", -- compiled Faust artifact (device-side)
	slot = 2,
	params = {
		{ label = "Sensitivity", min = -60, max = -12, init = -40, step = 0.5, unit = "dB" },
		{ label = "Attack", min = 0.05, max = 3, init = 0.6, step = 0.01, unit = "s" },
		{ label = "Release", min = 0.02, max = 2, init = 0.25, step = 0.01, unit = "s" },
		{ label = "Depth", min = 0, max = 1, init = 1, step = 0.01 },
		{ label = "Output", min = -12, max = 6, init = 0, step = 0.1, unit = "dB" },
	},
}
