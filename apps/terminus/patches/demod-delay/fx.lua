-- SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
return {
	{ label = "Time", min = 1, max = 2000, init = 300, step = 1, unit = "ms" },
	{ label = "Feedback", min = 0, max = 0.95, init = 0.4, step = 0.01 },
	{ label = "Mod Rate", min = 0.1, max = 10, init = 0.8, step = 0.01, unit = "Hz" },
	{ label = "Mod Depth", min = 0, max = 1, init = 0.3, step = 0.001 },
	{ label = "Tone", min = 0, max = 1, init = 0.5, step = 0.001 },
	{ label = "Mix", min = 0, max = 1, init = 0.4, step = 0.001 },
}
