-- SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
return {
	{ label = "Threshold", min = -60, max = 0, init = -30, step = 0.1, unit = "dB" },
	{ label = "Attack", min = 0.1, max = 100, init = 5, step = 0.1, unit = "ms" },
	{ label = "Release", min = 10, max = 2000, init = 200, step = 1, unit = "ms" },
	{ label = "Hold", min = 0, max = 500, init = 50, step = 1, unit = "ms" },
	{ label = "Mix", min = 0, max = 1, init = 0.5, step = 0.001 },
}
