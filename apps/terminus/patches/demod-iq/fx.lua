-- SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
return {
	{ label = "Low", min = 20, max = 2000, init = 80, step = 1, unit = "Hz" },
	{ label = "Mid", min = 200, max = 8000, init = 1200, step = 1, unit = "Hz" },
	{ label = "High", min = 2000, max = 20000, init = 5000, step = 1, unit = "Hz" },
	{ label = "Low Gain", min = -18, max = 18, init = 0, step = 0.1, unit = "dB" },
	{ label = "Mid Gain", min = -18, max = 18, init = 0, step = 0.1, unit = "dB" },
	{ label = "High Gain", min = -18, max = 18, init = 0, step = 0.1, unit = "dB" },
}
