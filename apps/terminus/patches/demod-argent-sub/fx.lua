-- SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
return {
	{ label = "Sub Cut", min = 20, max = 400, init = 80, step = 1, unit = "Hz" },
	{ label = "Sub Drive", min = 0, max = 1, init = 0.5, step = 0.001 },
	{ label = "Sub Level", min = 0, max = 1, init = 0.7, step = 0.001 },
	{ label = "Metal Root", min = 100, max = 800, init = 220, step = 0.1, unit = "Hz" },
	{ label = "Metal Q", min = 0.5, max = 12, init = 3, step = 0.01 },
	{ label = "Metal Drift", min = 0, max = 1, init = 0.3, step = 0.001 },
	{ label = "Metal Amount", min = 0, max = 1, init = 0.6, step = 0.001 },
	{ label = "Spread", min = 0, max = 1, init = 0.4, step = 0.001 },
}
