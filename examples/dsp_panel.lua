-- SPDX-License-Identifier: MPL-2.0
--[[
  Example: DSP control panel
  Demonstrates all built-in widgets in a typical layout.
  Run: ./demod-ui examples/dsp_panel.lua
]]

-- ── Layout ──────────────────────────────────────────────────────────

local root = dm.root()
root:set_layout("vbox", 8, 16)

-- Header
local header = dm.panel("header")
header:set_bounds(0, 0, 0, 48)
header:set_bg(0x12, 0x12, 0x20)
root:add_child(header)

local title = dm.label("title", "DSP Control")
title:set_fg(0x00, 0xF5, 0xD4)
title:set_bounds(16, 0, 400, 48)
header:add_child(title)

-- Main content area with two columns
local content = dm.panel("content")
content:set_bounds(0, 0, 0, 500)
content:set_layout("hbox", 12, 8)
content:set_bg(0x0A, 0x0A, 0x0F)
root:add_child(content)

-- ── Left Column: Effects Chain ──────────────────────────────────────

local left = dm.panel("left_col")
left:set_bounds(0, 0, 0, 0)
left:set_layout("vbox", 8, 12)
left:set_bg(0x14, 0x14, 0x24)
content:add_child(left)

local fx_title = dm.label("fx_title", "Effects Chain")
fx_title:set_fg(0x8B, 0x5C, 0xF6)
fx_title:set_bounds(0, 0, 0, 24)
left:add_child(fx_title)

-- Drive knob (slider)
local drive_label = dm.label("drive_label", "Drive")
drive_label:set_bounds(0, 0, 0, 20)
left:add_child(drive_label)

local drive = dm.slider("drive", 0.0, 1.0, 0.5)
drive:set_bounds(0, 0, 0, 24)
drive:on_change(function(w)
    local val = w:get_value()
    local pct = string.format("Drive: %.0f%%", val * 100)
    dm.find("drive_label"):set_text(pct)
    dm.redraw()
end)
left:add_child(drive)

-- Tone slider
local tone_label = dm.label("tone_label", "Tone")
tone_label:set_bounds(0, 0, 0, 20)
left:add_child(tone_label)

local tone = dm.slider("tone", 20.0, 20000.0, 5000.0)
tone:set_bounds(0, 0, 0, 24)
tone:on_change(function(w)
    local hz = w:get_value()
    local txt = string.format("Tone: %.0f Hz", hz)
    dm.find("tone_label"):set_text(txt)
    dm.redraw()
end)
left:add_child(tone)

-- Mix slider
local mix_label = dm.label("mix_label", "Mix")
mix_label:set_bounds(0, 0, 0, 20)
left:add_child(mix_label)

local mix = dm.slider("mix", 0.0, 1.0, 0.75)
mix:set_bounds(0, 0, 0, 24)
mix:on_change(function(w)
    local txt = string.format("Mix: %.0f%%", w:get_value() * 100)
    dm.find("mix_label"):set_text(txt)
    dm.redraw()
end)
left:add_child(mix)

-- Bypass toggle
local bypass_row = dm.panel("bypass_row")
bypass_row:set_bounds(0, 0, 0, 32)
bypass_row:set_layout("hbox", 8, 4)
bypass_row:set_bg(0x14, 0x14, 0x24)
left:add_child(bypass_row)

local bypass_label = dm.label("bypass_label", "Bypass")
bypass_label:set_bounds(0, 0, 60, 24)
bypass_row:add_child(bypass_label)

local bypass = dm.toggle("bypass", false)
bypass:set_bounds(0, 0, 50, 24)
bypass:on_change(function(w)
    local state = w:get_value() and "ON" or "OFF"
    dm.find("bypass_label"):set_text("Bypass: " .. state)
    dm.redraw()
end)
bypass_row:add_child(bypass)

-- ── Right Column: Presets & Status ──────────────────────────────────

local right = dm.panel("right_col")
right:set_bounds(0, 0, 0, 0)
right:set_layout("vbox", 8, 12)
right:set_bg(0x14, 0x14, 0x24)
content:add_child(right)

local preset_title = dm.label("preset_title", "Presets")
preset_title:set_fg(0x8B, 0x5C, 0xF6)
preset_title:set_bounds(0, 0, 0, 24)
right:add_child(preset_title)

-- Preset buttons
local presets = {"Clean", "Crunch", "Metal", "Ambient"}
for i, name in ipairs(presets) do
    local btn = dm.button("preset_" .. i, name)
    btn:set_bounds(0, 0, 0, 32)
    btn:on_click(function(w)
        dm.find("status"):set_text("Loaded: " .. name)
        dm.redraw()
    end)
    right:add_child(btn)
end

-- Preset name input
local name_input = dm.text_input("preset_name", "Enter preset name...")
name_input:set_bounds(0, 0, 0, 32)
right:add_child(name_input)

local save_btn = dm.button("save_preset", "Save Preset")
save_btn:set_bounds(0, 0, 0, 32)
save_btn:set_bg(0x8B, 0x5C, 0xF6)
save_btn:on_click(function(w)
    local name = dm.find("preset_name"):get_value()
    if name and #name > 0 then
        dm.find("status"):set_text("Saved: " .. name)
    else
        dm.find("status"):set_text("Enter a name first!")
    end
    dm.redraw()
end)
right:add_child(save_btn)

-- ── Footer: Status Bar ──────────────────────────────────────────────

local footer = dm.panel("footer")
footer:set_bounds(0, 0, 0, 32)
footer:set_bg(0x12, 0x12, 0x20)
root:add_child(footer)

local status = dm.label("status", "Ready — v0.1.0")
status:set_fg(0x66, 0x66, 0x77)
status:set_bounds(16, 0, 600, 32)
footer:add_child(status)

-- CPU meter (progress bar)
local cpu_bar = dm.progress("cpu_meter", 0.0)
cpu_bar:set_bounds(620, 8, 200, 16)
footer:add_child(cpu_bar)

-- ── Update Loop ─────────────────────────────────────────────────────

local phase = 0
function on_update(dt)
    -- Simulate CPU load oscillation
    phase = phase + dt * 0.5
    local load = 0.3 + 0.2 * math.sin(phase)
    dm.find("cpu_meter"):set_value(load)
    dm.redraw()
end

-- ── Custom Draw (overlay) ───────────────────────────────────────────

function on_draw()
    -- Draw a subtle gradient accent line at the top
    dm.draw.gradient_v(0, 0, 1280, 3,
        0x00, 0xF5, 0xD4,  -- turquoise
        0x8B, 0x5C, 0xF6)  -- violet
end
