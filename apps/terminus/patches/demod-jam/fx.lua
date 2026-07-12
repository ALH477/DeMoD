-- SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
-- ============================================================================
--  fx.lua — DCF-Audio phase-mod codec (codec_id 2) parameter authority.
--
--  Ranges mirror the Faust `nentry` controls in dcf_pm_codec.dsp. These are the
--  synthesis params the certified 8-byte PM block (dcf_audio.pm_pack) carries on
--  the wire — so this file is the single source of truth that turns musical,
--  real-unit values into the byte layout the C/Rust/Python references certify.
--
--  Only the 8-byte LAYOUT is certified (DCF_AUDIO_SPEC.md); the real-unit ->
--  byte quantisation below is a UX convention, deliberately reversible:
--    f0        Hz            -> u16  (clamped 20..8000)
--    amp       0..1          -> u8   (v*255)
--    mod_index 0..8          -> u8   (v/8*255)
--    mod_ratio 0.25..8       -> u8   Q4 fixed-point (v*16)  [1.0 -> 16]
--    bright    0..1          -> u8   (v*255)
--    env       0..1          -> u8   (v*255)
-- ============================================================================
local FX = {}

-- Param descriptors (Faust nentry ranges) — drives any host-side editor.
FX.params = {
	{ key = "f0",        label = "F0",        min = 20,   max = 8000, init = 220.0 },
	{ key = "amp",       label = "Amp",       min = 0,    max = 1,    init = 0.5 },
	{ key = "mod_index", label = "Mod Index", min = 0,    max = 8,    init = 1.0 },
	{ key = "mod_ratio", label = "Mod Ratio", min = 0.25, max = 8,    init = 1.0 },
	{ key = "bright",    label = "Bright",    min = 0,    max = 1,    init = 0.0 },
	{ key = "env",       label = "Env",       min = 1,    max = 1,    init = 1.0 },
}

local floor, min, max = math.floor, math.min, math.max
local function clampu8(v)
	return max(0, min(255, floor(v + 0.5)))
end

-- defaults(): real-unit param table from the descriptor init values.
function FX.defaults()
	local d = {}
	for _, p in ipairs(FX.params) do
		d[p.key] = p.init
	end
	return d
end

-- pm_block(overrides): real-unit params (init values overlaid with `overrides`,
-- also in real units) -> the integer field table ready for dcf_audio.pm_pack.
-- This is what makes the fx.lua controls travel as the certified 8-byte block.
function FX.pm_block(overrides)
	local v = FX.defaults()
	if overrides then
		for k, x in pairs(overrides) do
			v[k] = x
		end
	end
	return {
		f0        = max(20, min(8000, floor(v.f0 + 0.5))),
		amp       = clampu8(v.amp * 255),
		mod_index = clampu8(v.mod_index / 8 * 255),
		mod_ratio = clampu8(v.mod_ratio * 16),
		bright    = clampu8(v.bright * 255),
		env       = clampu8(v.env * 255),
		flags     = overrides and overrides.flags or 0,
	}
end

return FX
