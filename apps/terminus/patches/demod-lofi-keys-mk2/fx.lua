-- SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
return {
	-- PIANO
	{ label = "Attack", min = 0.001, max = 0.20, init = 0.003, step = 0.001, unit = "s" },
	{ label = "Ring", min = 0.15, max = 6.0, init = 1.60, step = 0.001, unit = "s" },
	{ label = "Release", min = 0.02, max = 3.0, init = 0.30, step = 0.001, unit = "s" },
	{ label = "Color", min = 0.0, max = 1.0, init = 0.55, step = 0.001 },
	{ label = "Tine", min = 0.0, max = 1.0, init = 0.40, step = 0.001 },
	{ label = "Growl", min = 0.0, max = 1.0, init = 0.35, step = 0.001 },
	{ label = "Detune", min = 0.0, max = 25.0, init = 5.0, step = 0.01, unit = "cent" },
	{ label = "Drift", min = 0.0, max = 30.0, init = 3.0, step = 0.01, unit = "cent" },
	{ label = "Mechanics", min = 0.0, max = 1.0, init = 0.25, step = 0.001 },

	-- TAPE
	{ label = "Saturation", min = 0.0, max = 1.0, init = 0.15, step = 0.001 },
	{ label = "Head Bump", min = 0.0, max = 1.0, init = 0.30, step = 0.001 },
	{ label = "Wobble", min = 0.0, max = 1.0, init = 0.35, step = 0.001 },
	{ label = "Dropouts", min = 0.0, max = 1.0, init = 0.20, step = 0.001 },
	{ label = "Bandwidth", min = 1200, max = 18000, init = 9000, step = 1, unit = "Hz" },
	{ label = "BitDepth", min = 4, max = 16, init = 14, step = 0.01 },
	{ label = "SR Reduce", min = 1, max = 12, init = 1, step = 0.1 },

	-- VINYL
	{ label = "Crackle", min = 0.0, max = 1.0, init = 0.22, step = 0.001 },
	{ label = "Wear", min = 0.0, max = 1.0, init = 0.40, step = 0.001 },
}
