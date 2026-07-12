-- SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
return {
	{ label = "Freq", min = 20, max = 20000, init = 220, step = 0.01, unit = "Hz" },
	{ label = "Gain", min = 0, max = 1, init = 0.8, step = 0.001 },
	{ label = "Stiffness", min = 0, max = 1, init = 0.5, step = 0.001 },
	{ label = "Attack", min = 0.001, max = 0.5, init = 0.01, step = 0.001, unit = "s" },
	{ label = "Decay", min = 0.05, max = 4.0, init = 0.8, step = 0.01, unit = "s" },
	{ label = "Taper", min = 0, max = 1, init = 0.5, step = 0.001 },
	{ label = "FM Transient", min = 0, max = 1, init = 0.4, step = 0.001 },
	{ label = "FM Ratio", min = 0.5, max = 8.0, init = 2.0, step = 0.01 },
}
