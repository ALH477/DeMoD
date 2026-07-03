-- SPDX-License-Identifier: MPL-2.0
--[[
  Minimal example — panel, label, button
  Just a panel with a label and a button.
]]

local root = dm.root()
root:set_layout("vbox", 16, 32)

local greeting = dm.label("greeting", "Hello, world!")
greeting:set_fg(0x00, 0xF5, 0xD4)
greeting:set_bounds(0, 0, 0, 40)
root:add_child(greeting)

local count = 0
local counter = dm.label("counter", "Clicks: 0")
counter:set_bounds(0, 0, 0, 24)
root:add_child(counter)

local btn = dm.button("click_me", "Click Me")
btn:set_bounds(0, 0, 200, 40)
btn:on_click(function(w)
    count = count + 1
    dm.find("counter"):set_text("Clicks: " .. count)
    dm.redraw()
end)
root:add_child(btn)

local quit_btn = dm.button("quit", "Quit")
quit_btn:set_bounds(0, 0, 200, 40)
quit_btn:set_bg(0xFF, 0x4C, 0x6A)
quit_btn:set_fg(0xFF, 0xFF, 0xFF)
quit_btn:on_click(function(w)
    dm.quit()
end)
root:add_child(quit_btn)
