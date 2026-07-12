-- SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
return {
	{ label = "Freq", min = 32.7, max = 1760, init = 220, step = 0.01, unit = "Hz" },
	{ label = "Gate", min = 0, max = 1, init = 0, step = 1 },
	{ label = "Gain", min = 0, max = 1, init = 0.8, step = 0.001 },
	{ label = "Hardness", min = 0, max = 1, init = 0.5, step = 0.001 },
	{ label = "Pick Pos", min = 0.01, max = 0.49, init = 0.12, step = 0.001 },
	{ label = "Inharmonicity", min = 0, max = 1, init = 0.3, step = 0.001 },
	{ label = "Damping", min = 0, max = 1, init = 0.5, step = 0.001 },
	{ label = "Torsion", min = 0, max = 0.45, init = 0.15, step = 0.001 },
}
