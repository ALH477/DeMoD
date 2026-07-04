-- SPDX-License-Identifier: MPL-2.0
-- settings.lua — theme / units / data-source, persisted via ctx.save().
local S = { name = "SETTINGS", focus = 1 }

local ROWS = {
  { key = "theme",       label = "Theme",       opts = { "night", "day", "auto" } },
  { key = "speed_units", label = "Speed units", opts = { "km/h", "mph" } },
  { key = "temp_units",  label = "Temp units",  opts = { "C", "F" } },
  { key = "provider",    label = "Data source", opts = { "auto", "obd2", "sim" } },
}

function S.draw(ctx)
  local th, U, W, H = ctx.th, ctx.U, ctx.W, ctx.H
  U.text(24, 58, "SETTINGS", th.accent, 2)
  local x, y, rh = 24, 110, 52
  for i, r in ipairs(ROWS) do
    local ry = y + (i - 1) * rh
    local sel = (i == S.focus)
    U.panel(x, ry, W - 48, rh - 8, sel and th.panel2 or th.panel, 255, sel and th.accent or nil)
    U.text(x + 18, ry + 16, r.label, sel and th.text or th.dim, 1)
    U.textr(x + W - 48 - 18, ry + 10, tostring(ctx.cfg[r.key]), sel and th.accent2 or th.text, 2)
  end
  U.text(24, H - 52, "turn: move    press: change    OBD device: " .. tostring(ctx.cfg.obd_dev), th.dim, 1)
end

function S.nav(action, ctx)
  if action == "prev" then S.focus = (S.focus - 2) % #ROWS + 1; return true end
  if action == "next" then S.focus = S.focus % #ROWS + 1; return true end
  if action == "activate" then
    local r = ROWS[S.focus]
    local cur, idx = ctx.cfg[r.key], 1
    for i, o in ipairs(r.opts) do if o == cur then idx = i break end end
    ctx.cfg[r.key] = r.opts[idx % #r.opts + 1]
    ctx.save()
    return true
  end
  return false
end

return S
