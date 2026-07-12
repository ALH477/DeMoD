-- SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
--[[ ============================================================================
  patches/demod-ks/fx.lua — fx descriptor for the DeMoD KS String plucked
  physical model (see demod_ks.dsp). Params 0..7 match declaration order;
  freq/gain/gate are the hidden MIDI-driven voice params.
  © 2026 DeMoD LLC. Private.
============================================================================ ]]
local HERE = (debug.getinfo(1, "S").source:gsub("^@", "")):match("(.*)/[^/]*$") or "."

return {
	v = 1,
	name = "KS STRING",
	kind = "synth",
	path = HERE .. "/demod_ks.so", -- compiled Faust artifact (device-side)
	slot = 1, -- generator: head of the chain
	params = {
		{ label = "Bass Mode", min = 0, max = 1, init = 0, step = 1 },
		{ label = "Body", min = 0, max = 1, init = 0.5, step = 0.01 },
		{ label = "Damping", min = 0.88, max = 0.9998, init = 0.995, step = 0.0001 },
		{ label = "Drive", min = 0, max = 1, init = 0, step = 0.01 },
		{ label = "Pick Position", min = 5, max = 95, init = 33, step = 1, unit = "%" },
		{ label = "freq", min = 20, max = 20000, init = 440, step = 0.01, unit = "Hz" },
		{ label = "gain", min = 0, max = 1, init = 0.8, step = 0.01 },
		{ label = "gate", min = 0, max = 1, init = 0, step = 1 },
	},
}
