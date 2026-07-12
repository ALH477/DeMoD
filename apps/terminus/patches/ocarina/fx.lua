-- SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
return {
	-- Performance
	{ label = "freq", min = 80.0, max = 2200.0, init = 523.25, step = 0.001, unit = "Hz" },
	{ label = "gain", min = 0.0, max = 1.0, init = 0.85, step = 0.001 },
	{ label = "breath", min = 0.0, max = 1.0, init = 0.0, step = 0.001 },
	{ label = "bend", min = -2.0, max = 2.0, init = 0.0, step = 0.001, unit = "semi" },

	-- Embouchure
	{ label = "pressure_gain", min = 0.5, max = 4.0, init = 2.0, step = 0.001 },
	{ label = "jet_drive", min = 0.3, max = 3.0, init = 1.2, step = 0.001 },
	{ label = "vortex_loss", min = 0.0, max = 0.5, init = 0.05, step = 0.001 },

	-- Cavity
	{ label = "resonance", min = 6.0, max = 60.0, init = 28.0, step = 0.01 },
	{ label = "voicing", min = 0.0, max = 0.6, init = 0.12, step = 0.001 },

	-- Breath
	{ label = "threshold", min = 0.0, max = 0.6, init = 0.18, step = 0.001 },
	{ label = "breath_pitch", min = 0.0, max = 2.0, init = 0.6, step = 0.001, unit = "semi" },
	{ label = "breath_noise", min = 0.0, max = 0.3, init = 0.06, step = 0.001 },
	{ label = "attack_ms", min = 1.0, max = 200.0, init = 18.0, step = 0.1, unit = "ms" },
	{ label = "release_ms", min = 5.0, max = 600.0, init = 90.0, step = 0.1, unit = "ms" },

	-- Vibrato
	{ label = "depth", min = 0.0, max = 0.05, init = 0.010, step = 0.0001 },
	{ label = "rate_hz", min = 0.5, max = 9.0, init = 5.2, step = 0.01, unit = "Hz" },
	{ label = "tremolo", min = 0.0, max = 0.4, init = 0.06, step = 0.001 },
	{ label = "breath_flutter", min = 0.0, max = 0.3, init = 0.05, step = 0.001 },
	{ label = "tuning_drift", min = 0.0, max = 0.03, init = 0.004, step = 0.0001 },

	-- Output
	{ label = "stereo_air", min = 0.0, max = 1.0, init = 0.5, step = 0.001 },
	{ label = "master", min = -60.0, max = 6.0, init = -6.0, step = 0.1, unit = "dB" },
}
