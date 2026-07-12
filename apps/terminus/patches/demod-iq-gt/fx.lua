-- SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
return {
	{ label = "Low", min = 20, max = 2000, init = 120, step = 1, unit = "Hz" },
	{ label = "Mid", min = 200, max = 8000, init = 800, step = 1, unit = "Hz" },
	{ label = "Presence", min = 1000, max = 12000, init = 3000, step = 1, unit = "Hz" },
	{ label = "Low Gain", min = -18, max = 18, init = 0, step = 0.1, unit = "dB" },
	{ label = "Mid Gain", min = -18, max = 18, init = 3, step = 0.1, unit = "dB" },
	{ label = "Presence Gain", min = -12, max = 12, init = 2, step = 0.1, unit = "dB" },
}
