-- SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
return {
	{ label = "Freq", min = 27.5, max = 20000, init = 440, step = 0.01, unit = "Hz" },
	{ label = "Gate", min = 0, max = 1, init = 0, step = 1 },
	{ label = "Gain", min = 0, max = 1, init = 0.5, step = 0.01 },
	{ label = "Morph", min = 0, max = 3, init = 1.5, step = 0.001 },
	{ label = "Excite", min = 0, max = 1, init = 0.5, step = 0.001 },
	{ label = "Attack", min = 0.001, max = 2, init = 0.005, step = 0.001, unit = "s" },
	{ label = "Release", min = 0.05, max = 8, init = 1.5, step = 0.01, unit = "s" },
}
