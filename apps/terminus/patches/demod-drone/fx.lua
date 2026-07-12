-- SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
--[[ ============================================================================
  patches/demod-drone/fx.lua -- fx descriptor for DRONE (see demod_drone.dsp).
  Params match the COMPILED Faust control bus order (tools/sync_params.py).
  (c) 2026 DeMoD LLC. Private.
============================================================================ ]]
local HERE = (debug.getinfo(1, "S").source:gsub("^@", "")):match("(.*)/[^/]*$") or "."

return {
	v = 1,
	name = "DRONE",
	kind = "synth",
	path = HERE .. "/demod_drone.so", -- compiled Faust artifact (device-side)
	slot = 1,
	params = {
		{ label = "Root", min = 40, max = 440, init = 110, step = 0.1, unit = "Hz" },
		{ label = "Fifth", min = 0, max = 1, init = 0.6, step = 0.01 },
		{ label = "Octave", min = 0, max = 1, init = 0.4, step = 0.01 },
		{ label = "Detune", min = 0, max = 30, init = 6, step = 0.1, unit = "cents" },
		{ label = "Timbre", min = 0, max = 1, init = 0.5, step = 0.01 },
		{ label = "Level", min = 0, max = 1, init = 0.5, step = 0.01 },
	},
}
