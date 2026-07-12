-- SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
return {
	{ label = "Freq", min = 40, max = 2000, init = 220, step = 0.01, unit = "Hz" },
	{ label = "Gain", min = -60, max = 0, init = -12, step = 0.1, unit = "dB" },
	{ label = "Wobble Rate", min = 0.01, max = 4.0, init = 0.3, step = 0.01, unit = "Hz" },
	{ label = "Drift Depth", min = 0.0, max = 1.0, init = 0.25, step = 0.01 },
	{ label = "Water Cutoff", min = 50, max = 4000, init = 400, step = 1, unit = "Hz" },
	{ label = "Pressure Q", min = 0.5, max = 5.0, init = 1.0, step = 0.01 },
	{ label = "Feedback", min = 0.0, max = 0.97, init = 0.6, step = 0.01 },
	{ label = "Delay", min = 1, max = 1000, init = 250, step = 1, unit = "ms" },
}
