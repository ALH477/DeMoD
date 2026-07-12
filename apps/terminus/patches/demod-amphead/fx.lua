-- SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
return {
	-- Input
	{ label = "Gain", min = 0.0, max = 4.0, init = 1.0, step = 0.01 },
	{ label = "Bright", min = 0.0, max = 1.0, init = 0.3, step = 0.001 },
	{ label = "Preamp", min = 0.0, max = 1.0, init = 0.5, step = 0.001 },
	-- Tone (Bassman interactive stack)
	{ label = "Treble", min = 0.0, max = 1.0, init = 0.6, step = 0.001 },
	{ label = "Middle", min = 0.0, max = 1.0, init = 0.5, step = 0.001 },
	{ label = "Bass", min = 0.0, max = 1.0, init = 0.5, step = 0.001 },
	-- Power
	{ label = "Bias", min = -0.3, max = 0.3, init = 0.05, step = 0.001 },
	{ label = "Presence", min = 0.0, max = 1.0, init = 0.4, step = 0.001 },
	{ label = "Depth", min = 0.0, max = 1.0, init = 0.4, step = 0.001 },
	-- Output
	{ label = "Master", min = 0.0, max = 1.0, init = 0.5, step = 0.001 },
}
