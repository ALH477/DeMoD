-- SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
return {
	{ label = "Freq", min = 20, max = 2000, init = 60, step = 0.1, unit = "Hz" },
	{ label = "Gain", min = 0, max = 1, init = 0.8, step = 0.01 },
	{ label = "Damping", min = 0, max = 1, init = 0.4, step = 0.001 },
	{ label = "Decay", min = 0.1, max = 8, init = 1.2, step = 0.01, unit = "s" },
	{ label = "Air Load", min = 0, max = 1, init = 0.5, step = 0.001 },
	{ label = "Overtones", min = 0, max = 1, init = 0.35, step = 0.001 },
	{ label = "Volume", min = 0, max = 1, init = 0.8, step = 0.01 },
	{ label = "Strike Radius", min = 0, max = 1, init = 0.5, step = 0.001 },
}
