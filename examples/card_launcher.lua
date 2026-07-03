-- SPDX-License-Identifier: MPL-2.0
--[[
  Card launcher — encoder-native (dm.control demo)
  Uses dm.control for rotary-encoder friendly cards
]]

local root = dm.root()
root:set_layout("vbox", 0, 0)

local home = dm.control("home")
home:set_bounds(40, 40, dm.width()-80, 180)
root:add_child(home)

-- Channels as rectangular cards
local channels = {
    {id="dsp",     label="DSP Studio",   subtitle="Knobs • Waveform • XY", status="active"},
    {id="lyrics",  label="Lyrics",       subtitle="Media playback"      ,   status="active"},
    {id="viz",     label="Graph",       subtitle="Architecture view" ,  status="active"},
    {id="market",  label="Store",       subtitle="Browse items",            status="dev"},
    {id="settings",label="System",       subtitle="Audio • Network"     ,  status="active"},
}

for _, ch in ipairs(channels) do
    dm.control_add_item(home, ch)
end

dm.redraw()
