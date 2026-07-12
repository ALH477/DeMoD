-- SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
--[[ ============================================================================
  patches/demod-cab/fx.lua — fx descriptor for the cabinet voicing (see cab.dsp).
  Params 0..2 match cab.dsp. © 2026 DeMoD LLC. Private.
============================================================================ ]]
local HERE = (debug.getinfo(1, "S").source:gsub("^@", "")):match("(.*)/[^/]*$") or "."

return {
	v = 1,
	name = "CAB",
	kind = "fx",
	path = HERE .. "/cab.so", -- compiled Faust artifact (device-side)
	slot = 5, -- cabs usually sit at the end of the chain
	params = {
		{ label = "CAB", min = 0, max = 3, init = 0, step = 1 }, -- 4x12/2x12/1x12/combo
		{ label = "LEVEL", min = 0, max = 1, init = 0.8, step = 0.01, unit = "%" },
		{ label = "MIX", min = 0, max = 1, init = 1.0, step = 0.01, unit = "%" },
	},
}
