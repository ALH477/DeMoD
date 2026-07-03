-- SPDX-License-Identifier: MPL-2.0
--[[
  Systems graph — DSL demo
  Native C DSL + Lua population
]]

local root = dm.root()
root:set_layout("vbox", 0, 0)

local v = dm.viz("systems")
v:set_bounds(0, 0, dm.width(), dm.height())
root:add_child(v)

-- Seed data via the C DSL (add_item helper)
local nodes = {
    {type="node", id="hw",     label="Hardware",   layer=1, x=0,   y=300, depth=2, status="active"},
    {type="node", id="os",     label="OS"        ,layer=2, x=0,   y=120, depth=3, status="active"},
    {type="node", id="proto",  label="Protocol"  ,layer=3,x=0,  y=-80, depth=3, status="active"},
    {type="node", id="app",    label="App"     ,   layer=4, x=-120,y=-220,depth=2, status="active"},
    {type="node", id="net",    label="Mesh"     ,  layer=5, x=120, y=-220,depth=2, status="active"},
}

for _, n in ipairs(nodes) do
    dm.viz_add_item(v, n)
end

dm.viz_add_item(v, {type="node", id="tuner", label="Tuner", layer=4, x=-200, y=-120, depth=1, status="active"})

dm.redraw()
