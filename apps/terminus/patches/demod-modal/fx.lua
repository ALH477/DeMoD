-- SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
--[[ ============================================================================
  patches/demod-modal/fx.lua — fx descriptor for the DeMoD Modal Perc mallet
  physical model (see demod_modal.dsp). Params 0..6 match declaration order;
  freq/gain/gate are the hidden MIDI-driven voice params.
  © 2026 DeMoD LLC. Private.
============================================================================ ]]
local HERE = (debug.getinfo(1, "S").source:gsub("^@", "")):match("(.*)/[^/]*$") or "."

return {
	v = 1,
	name = "MODAL PERC",
	kind = "synth",
	path = HERE .. "/demod_modal.so", -- compiled Faust artifact (device-side)
	slot = 1, -- generator: head of the chain
	params = {
		{ label = "Fan Speed", min = 0, max = 7, init = 1.5, step = 0.01, unit = "Hz" },
		{ label = "Strike Position", min = 5, max = 95, init = 30, step = 1, unit = "%" },
		{ label = "T60", min = 0.3, max = 8, init = 3, step = 0.01, unit = "s" },
		{ label = "Vibraphone", min = 0, max = 1, init = 0, step = 1 },
		{ label = "freq", min = 20, max = 20000, init = 440, step = 0.01, unit = "Hz" },
		{ label = "gain", min = 0, max = 1, init = 0.8, step = 0.01 },
		{ label = "gate", min = 0, max = 1, init = 0, step = 1 },
	},
}
