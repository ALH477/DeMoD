-- SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
--[[ ============================================================================
  patches/demod-mf-ironwall/fx.lua -- fx descriptor for IronWall (see 01_IronWall.dsp), part of the
  Metal Forge suite.
  Params 0..3 match the widget declaration order in the .dsp.

  (c) 2026 DeMoD LLC. Private.
============================================================================ ]]
local HERE = (debug.getinfo(1, "S").source:gsub("^@", "")):match("(.*)/[^/]*$") or "."

return {
	v = 1,
	name = "IRONWALL",
	kind = "fx",
	path = HERE .. "/01_IronWall.so", -- compiled Faust artifact (device-side)
	slot = 2,
	params = {
		{ label = "Drive", min = 1, max = 40, init = 6, step = 0.01 },
		{ label = "Thresh", min = 0.05, max = 1, init = 0.5, step = 0.001 },
		{ label = "Trim", min = -24, max = 6, init = -6, step = 0.1, unit = "dB" },
		{ label = "Mix", min = 0, max = 1, init = 1, step = 0.01 },
	},
}
