-- SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
return {
	{ label = "Bit Depth", min = 4, max = 16, init = 8, step = 0.1 },
	{ label = "Sample Rate", min = 500, max = 44100, init = 22050, step = 10, unit = "Hz" },
	{ label = "Tone", min = 0, max = 1, init = 0.5, step = 0.001 },
	{ label = "Mix", min = 0, max = 1, init = 0.5, step = 0.001 },
}
