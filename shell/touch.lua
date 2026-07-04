-- SPDX-License-Identifier: MPL-2.0
-- touch.lua — touch/pointer for custom-drawn shells. The framework delivers
-- pointer events only to widgets, so we keep a pool of transparent dm.buttons
-- added to dm.root(), repositioned each frame over the active surface's tap
-- zones + the tab bar. Their on_click runs the same actions as the on_nav
-- funnel. The shell's on_draw paints over the whole widget layer, so the
-- buttons are invisible yet still receive taps. (The private home.lua pattern.)
local T = {}
local pool = {}

local function slot(i)
  if not pool[i] then
    local b = dm.button("shell_tap_" .. i, "")
    if b.set_bg then b:set_bg(0, 0, 0, 0) end   -- transparent
    dm.root():add_child(b)
    local s = { btn = b, fn = nil }
    b:on_click(function() if s.fn then s.fn() end end)
    pool[i] = s
  end
  return pool[i]
end

-- zones: array of { x, y, w, h, on = function() ... end }
function T.frame(zones)
  local i = 0
  for _, z in ipairs(zones) do
    i = i + 1
    local s = slot(i)
    s.btn:set_bounds(math.floor(z.x), math.floor(z.y), math.floor(z.w), math.floor(z.h))
    s.btn:show()
    s.fn = z.on
  end
  for j = i + 1, #pool do pool[j].btn:hide(); pool[j].fn = nil end
end

return T
