-- SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
--[[ ============================================================================
  patches/demod-boost/fx.lua -- fx descriptor for BOOST (see demod_boost.dsp).
  Params match the COMPILED Faust control bus order (tools/sync_params.py).
  (c) 2026 DeMoD LLC. Private.
============================================================================ ]]
local HERE = (debug.getinfo(1, "S").source:gsub("^@", "")):match("(.*)/[^/]*$") or "."

return {
	v = 1,
	name = "BOOST",
	kind = "fx",
	path = HERE .. "/demod_boost.so", -- compiled Faust artifact (device-side)
	slot = 2,
	params = {
		{ label = "Boost", min = 0, max = 24, init = 6, step = 0.1, unit = "dB" },
		{ label = "Treble", min = -6, max = 12, init = 3, step = 0.1, unit = "dB" },
		{ label = "Range", min = 0, max = 1, init = 0.3, step = 0.01 },
		{ label = "Level", min = -12, max = 6, init = 0, step = 0.1, unit = "dB" },
	},
}
