-- SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
return {
	{ label = "Root Note", min = 0, max = 11, init = 0, step = 1 },
	{ label = "JI Blend", min = 0, max = 1, init = 0.6, step = 0.01 },
	{ label = "Portamento", min = 0, max = 1, init = 0.05, step = 0.001, unit = "s" },
	{ label = "Vibrato Rate", min = 0.1, max = 12, init = 5, step = 0.01, unit = "Hz" },
	{ label = "Vibrato Depth", min = 0, max = 2, init = 0.25, step = 0.01, unit = "st" },
	{ label = "Jitter", min = 0, max = 1, init = 0.45, step = 0.01 },
	{ label = "Inharmonicity", min = 0, max = 0.05, init = 0.001, step = 0.0001 },
	{ label = "Brightness", min = 0, max = 1, init = 0.55, step = 0.01 },
}
