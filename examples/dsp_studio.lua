-- SPDX-License-Identifier: MPL-2.0
--[[
  Example: DSP studio
  Full demonstration of all widget types.
  Run: ./demod-ui examples/dsp_studio.lua
]]

-- ── Root Layout ─────────────────────────────────────────────────────

local root = dm.root()
root:set_layout("vbox", 4, 8)

-- ── Header Bar ──────────────────────────────────────────────────────

local header = dm.panel("header")
header:set_bounds(0, 0, 0, 40)
header:set_bg(0x10, 0x10, 0x1C)
root:add_child(header)

local title = dm.label("title", "DSP Studio")
title:set_fg(0x00, 0xF5, 0xD4)
title:set_bounds(12, 0, 300, 40)
header:add_child(title)

-- Preset dropdown in header
local preset_dd = dm.dropdown("presets", "Select Preset...")
preset_dd:set_bounds(320, 6, 220, 28)
preset_dd:add_item("Init Patch")
preset_dd:add_item("Warm Pad")
preset_dd:add_item("Metal Crunch")
preset_dd:add_item("Ambient Shimmer")
preset_dd:add_item("Bass Station")
preset_dd:add_item("Lead Synth")
preset_dd:on_change(function(w)
    dm.find("status"):set_text("Preset: " .. (w:get_value() or "None"))
    dm.redraw()
end)
header:add_child(preset_dd)

-- ── Main Content: 3 columns ─────────────────────────────────────────

local main = dm.panel("main")
main:set_bounds(0, 0, 0, 560)
main:set_layout("hbox", 8, 8)
main:set_bg(0x0A, 0x0A, 0x0F)
root:add_child(main)

-- ─── Left: Knob Bank ────────────────────────────────────────────────

local knob_panel = dm.panel("knob_panel")
knob_panel:set_bounds(0, 0, 320, 0)
knob_panel:set_layout("vbox", 4, 8)
knob_panel:set_bg(0x12, 0x12, 0x20)
main:add_child(knob_panel)

local knob_title = dm.label("knob_title", "Oscillator")
knob_title:set_fg(0x8B, 0x5C, 0xF6)
knob_title:set_bounds(0, 0, 0, 22)
knob_panel:add_child(knob_title)

-- Top row of knobs
local knob_row1 = dm.panel("knob_row1")
knob_row1:set_bounds(0, 0, 0, 110)
knob_row1:set_layout("hbox", 4, 4)
knob_row1:set_bg(0x12, 0x12, 0x20)
knob_panel:add_child(knob_row1)

local freq_knob = dm.knob("freq", "Freq", 20.0, 20000.0, 440.0)
freq_knob:set_format("%.0f Hz")
freq_knob:set_bounds(0, 0, 0, 0)
freq_knob:on_change(function(w)
    dm.find("status"):set_text(string.format("Freq: %.0f Hz", w:get_value()))
    dm.redraw()
end)
knob_row1:add_child(freq_knob)

local resonance = dm.knob("reso", "Reso", 0.0, 1.0, 0.3)
resonance:set_format("%.2f")
resonance:set_bounds(0, 0, 0, 0)
knob_row1:add_child(resonance)

local detune = dm.knob("detune", "Detune", -100.0, 100.0, 0.0)
detune:set_format("%.0f ct")
detune:set_bounds(0, 0, 0, 0)
knob_row1:add_child(detune)

-- Second row
local filter_title = dm.label("filter_title", "Filter")
filter_title:set_fg(0x8B, 0x5C, 0xF6)
filter_title:set_bounds(0, 0, 0, 22)
knob_panel:add_child(filter_title)

local knob_row2 = dm.panel("knob_row2")
knob_row2:set_bounds(0, 0, 0, 110)
knob_row2:set_layout("hbox", 4, 4)
knob_row2:set_bg(0x12, 0x12, 0x20)
knob_panel:add_child(knob_row2)

local cutoff = dm.knob("cutoff", "Cutoff", 20.0, 20000.0, 8000.0)
cutoff:set_format("%.0f Hz")
cutoff:set_bounds(0, 0, 0, 0)
knob_row2:add_child(cutoff)

local q_knob = dm.knob("q", "Q", 0.1, 20.0, 0.707)
q_knob:set_format("%.2f")
q_knob:set_bounds(0, 0, 0, 0)
knob_row2:add_child(q_knob)

local drive_knob = dm.knob("drive", "Drive", 0.0, 1.0, 0.0)
drive_knob:set_format("%.0f%%")
drive_knob:set_bounds(0, 0, 0, 0)
knob_row2:add_child(drive_knob)

-- Envelope
local env_title = dm.label("env_title", "Envelope")
env_title:set_fg(0x8B, 0x5C, 0xF6)
env_title:set_bounds(0, 0, 0, 22)
knob_panel:add_child(env_title)

local knob_row3 = dm.panel("knob_row3")
knob_row3:set_bounds(0, 0, 0, 110)
knob_row3:set_layout("hbox", 2, 2)
knob_row3:set_bg(0x12, 0x12, 0x20)
knob_panel:add_child(knob_row3)

local atk = dm.knob("atk", "A", 0.001, 5.0, 0.01)
atk:set_format("%.3fs")
knob_row3:add_child(atk)

local dec = dm.knob("dec", "D", 0.001, 5.0, 0.2)
dec:set_format("%.3fs")
knob_row3:add_child(dec)

local sus = dm.knob("sus", "S", 0.0, 1.0, 0.7)
sus:set_format("%.2f")
knob_row3:add_child(sus)

local rel = dm.knob("rel", "R", 0.001, 10.0, 0.5)
rel:set_format("%.3fs")
knob_row3:add_child(rel)

-- ─── Center: Waveform + XY Pad ─────────────────────────────────────

local center = dm.panel("center")
center:set_bounds(0, 0, 0, 0)
center:set_layout("vbox", 8, 8)
center:set_bg(0x0E, 0x0E, 0x18)
main:add_child(center)

local scope_title = dm.label("scope_title", "Oscilloscope")
scope_title:set_fg(0x8B, 0x5C, 0xF6)
scope_title:set_bounds(0, 0, 0, 22)
center:add_child(scope_title)

local scope = dm.waveform("scope", 1024)
scope:set_bounds(0, 0, 0, 160)
center:add_child(scope)

local xy_title = dm.label("xy_title", "XY Modulation Pad")
xy_title:set_fg(0x8B, 0x5C, 0xF6)
xy_title:set_bounds(0, 0, 0, 22)
center:add_child(xy_title)

local xy = dm.xy_pad("xy_mod")
xy:set_bounds(0, 0, 0, 220)
xy:on_change(function(w)
    local x, y = w:get_xy()
    dm.find("xy_readout"):set_text(
        string.format("X: %.2f  Y: %.2f", x, y))
    dm.redraw()
end)
center:add_child(xy)

local xy_readout = dm.label("xy_readout", "X: 0.50  Y: 0.50")
xy_readout:set_fg(0x66, 0x66, 0x77)
xy_readout:set_bounds(0, 0, 0, 20)
center:add_child(xy_readout)

-- Output controls row
local out_row = dm.panel("out_row")
out_row:set_bounds(0, 0, 0, 36)
out_row:set_layout("hbox", 8, 4)
out_row:set_bg(0x0E, 0x0E, 0x18)
center:add_child(out_row)

local bypass_label = dm.label("bypass_lbl", "Bypass")
bypass_label:set_bounds(0, 0, 60, 32)
out_row:add_child(bypass_label)

local bypass = dm.toggle("bypass", false)
bypass:set_bounds(0, 0, 50, 32)
out_row:add_child(bypass)

local mono_label = dm.label("mono_lbl", "Mono")
mono_label:set_bounds(0, 0, 50, 32)
out_row:add_child(mono_label)

local mono = dm.toggle("mono", false)
mono:set_bounds(0, 0, 50, 32)
out_row:add_child(mono)

-- ─── Right: VU Meters + Mix ─────────────────────────────────────────

local right = dm.panel("right_col")
right:set_bounds(0, 0, 180, 0)
right:set_layout("vbox", 8, 8)
right:set_bg(0x12, 0x12, 0x20)
main:add_child(right)

local vu_title = dm.label("vu_title", "Output")
vu_title:set_fg(0x8B, 0x5C, 0xF6)
vu_title:set_bounds(0, 0, 0, 22)
right:add_child(vu_title)

local vu = dm.vu_meter("vu_out", 2)
vu:set_bounds(0, 0, 0, 200)
right:add_child(vu)

local vol_label = dm.label("vol_label", "Volume")
vol_label:set_bounds(0, 0, 0, 20)
right:add_child(vol_label)

local volume = dm.slider("volume", 0.0, 1.0, 0.75)
volume:set_bounds(0, 0, 0, 24)
volume:on_change(function(w)
    dm.find("vol_label"):set_text(
        string.format("Volume: %.0f%%", w:get_value() * 100))
    dm.redraw()
end)
right:add_child(volume)

local pan_label = dm.label("pan_label", "Pan")
pan_label:set_bounds(0, 0, 0, 20)
right:add_child(pan_label)

local pan = dm.slider("pan", -1.0, 1.0, 0.0)
pan:set_bounds(0, 0, 0, 24)
pan:on_change(function(w)
    local v = w:get_value()
    local txt
    if math.abs(v) < 0.05 then txt = "Pan: C"
    elseif v < 0 then txt = string.format("Pan: L%.0f", -v * 100)
    else txt = string.format("Pan: R%.0f", v * 100)
    end
    dm.find("pan_label"):set_text(txt)
    dm.redraw()
end)
right:add_child(pan)

-- Mix/Send section
local mix_title = dm.label("mix_title", "FX Send")
mix_title:set_fg(0x8B, 0x5C, 0xF6)
mix_title:set_bounds(0, 0, 0, 22)
right:add_child(mix_title)

local reverb_label = dm.label("reverb_label", "Reverb")
reverb_label:set_bounds(0, 0, 0, 18)
right:add_child(reverb_label)

local reverb = dm.slider("reverb", 0.0, 1.0, 0.3)
reverb:set_bounds(0, 0, 0, 24)
right:add_child(reverb)

local delay_label = dm.label("delay_label", "Delay")
delay_label:set_bounds(0, 0, 0, 18)
right:add_child(delay_label)

local delay = dm.slider("delay", 0.0, 1.0, 0.15)
delay:set_bounds(0, 0, 0, 24)
right:add_child(delay)

-- CPU load bar
local cpu = dm.progress("cpu", 0.0)
cpu:set_bounds(0, 0, 0, 12)
right:add_child(cpu)

-- ── Footer ──────────────────────────────────────────────────────────

local footer = dm.panel("footer")
footer:set_bounds(0, 0, 0, 28)
footer:set_bg(0x10, 0x10, 0x1C)
root:add_child(footer)

local status = dm.label("status", "Ready — v0.1.0")
status:set_fg(0x55, 0x55, 0x66)
status:set_bounds(12, 0, 800, 28)
footer:add_child(status)

-- ── Simulation Loop ─────────────────────────────────────────────────

local phase = 0
local lfo_phase = 0

function on_update(dt)
    local freq_val = dm.find("freq"):get_value()
    local reso_val = dm.find("reso"):get_value()

    -- Generate simulated waveform
    local scope_w = dm.find("scope")
    for i = 1, 4 do
        phase = phase + freq_val * dt * 0.25
        local sample = math.sin(phase * 2 * math.pi)
            + reso_val * 0.5 * math.sin(phase * 4 * math.pi)
            + 0.1 * math.sin(phase * 7 * math.pi)
        sample = sample / (1.0 + reso_val)
        scope_w:push_sample(sample)
    end

    -- LFO for VU meter simulation
    lfo_phase = lfo_phase + dt * 2.0
    local vol_val = dm.find("volume"):get_value()
    local pan_val = dm.find("pan"):get_value()
    local base = 0.4 + 0.3 * math.abs(math.sin(lfo_phase))
    local l_level = base * vol_val * (1.0 - math.max(0, pan_val))
    local r_level = base * vol_val * (1.0 + math.min(0, pan_val))
    l_level = l_level + 0.05 * math.random()
    r_level = r_level + 0.05 * math.random()

    local vu_w = dm.find("vu_out")
    vu_w:set_level(0, l_level)
    vu_w:set_level(1, r_level)
    vu_w:vu_update(dt)

    -- Simulated CPU load
    local load = 0.2 + 0.15 * math.sin(lfo_phase * 0.3)
        + (dm.find("drive"):get_value() * 0.15)
        + (dm.find("reverb"):get_value() * 0.1)
        + (dm.find("delay"):get_value() * 0.08)
    dm.find("cpu"):set_value(load)

    dm.redraw()
end

-- ── Custom Overlay ──────────────────────────────────────────────────

function on_draw()
    -- Turquoise-violet gradient at top
    dm.draw.gradient_v(0, 0, 1280, 2,
        0x00, 0xF5, 0xD4,
        0x8B, 0x5C, 0xF6)
end
