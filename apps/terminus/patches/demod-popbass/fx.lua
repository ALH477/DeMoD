-- SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
return {
	{ label = "Freq", min = 20, max = 800, init = 80, step = 0.1, unit = "Hz" },
	{ label = "Detune", min = 0, max = 50, init = 8, step = 0.1, unit = "cent" },
	{ label = "Sub Mix", min = 0, max = 1, init = 0.35, step = 0.001 },
	{ label = "Glide", min = 0, max = 0.5, init = 0, step = 0.001, unit = "s" },
	{ label = "Cutoff", min = 20, max = 16000, init = 600, step = 1, unit = "Hz" },
	{ label = "Resonance", min = 0.5, max = 12, init = 3, step = 0.01 },
	{ label = "Env Amt", min = 0, max = 1, init = 0.65, step = 0.001 },
	{ label = "F.Attack", min = 0.001, max = 2, init = 0.003, step = 0.001, unit = "s" },
}
