-- SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
return {
	{ label = "Threshold", min = -30, max = 0, init = -6, step = 0.1, unit = "dB" },
	{ label = "Attack", min = 0.01, max = 50, init = 1, step = 0.1, unit = "ms" },
	{ label = "Release", min = 10, max = 500, init = 50, step = 1, unit = "ms" },
	{ label = "Ceiling", min = -6, max = 0, init = -0.3, step = 0.1, unit = "dB" },
}
