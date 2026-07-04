-- SPDX-License-Identifier: MPL-2.0
-- dashboard.lua — the driving cluster: speedo + tach + coolant/fuel/batt/throttle.
local D = { name = "DRIVE" }

local function mini(ctx, x, y, w, h, label, value, col)
  local th, U = ctx.th, ctx.U
  U.panel(x, y, w, h, th.panel, 255, col)
  U.text(x + 12, y + 10, label, th.dim, 1)
  U.text(x + 12, y + h - 26, value, th.text, 2)
end

function D.draw(ctx)
  local th, U, W, H, v = ctx.th, ctx.U, ctx.W, ctx.H, ctx.veh
  local mph = ctx.units.speed == "mph"
  local sp = v.speed * (mph and 0.621371 or 1)
  local spmax = mph and 100 or 160
  local a0, a1 = math.rad(140), math.rad(400)

  -- speedo (center-left)
  local cx, cy = math.floor(W * 0.31), math.floor(H * 0.47)
  local rad = math.floor(math.min(W, H) * 0.25)
  U.arc(cx, cy, rad, a0, a1, sp / spmax, 11, th.ring, th.accent)
  U.needle(cx, cy, rad - 16, a0, a1, sp / spmax, th.needle)
  U.textc(cx, cy - 52, string.format("%.0f", sp), th.text, 6)
  U.textc(cx, cy + 52, mph and "mph" or "km/h", th.dim, 1)
  U.textc(cx, cy + 74, "GEAR " .. tostring(v.gear), th.accent2, 2)

  -- tach (right)
  local tx, ty = math.floor(W * 0.72), cy
  local trad = math.floor(rad * 0.78)
  local rcol = v.rpm > 6000 and th.alert or th.accent
  U.arc(tx, ty, trad, a0, a1, v.rpm / 7000, 9, th.ring, rcol)
  U.textc(tx, ty - 32, string.format("%.0f", v.rpm), th.text, 4)
  U.textc(tx, ty + 40, "RPM", th.dim, 1)

  -- stat row (kept above the shell's bottom tab bar at H-32)
  local coolant = v.coolant * (ctx.units.temp == "F" and 9 / 5 or 1) + (ctx.units.temp == "F" and 32 or 0)
  local y, pw, x = H - 116, math.floor((W - 40) / 4), 20
  mini(ctx, x, y, pw - 10, 68, "COOLANT",
    string.format("%.0f%s", coolant, ctx.units.temp == "F" and "F" or "C"),
    v.coolant > 105 and th.alert or th.accent); x = x + pw
  mini(ctx, x, y, pw - 10, 68, "FUEL", string.format("%.0f%%", v.fuel),
    v.fuel < 12 and th.warn or th.ok); x = x + pw
  mini(ctx, x, y, pw - 10, 68, "BATTERY", string.format("%.1fV", v.volts),
    v.volts < 12.0 and th.warn or th.ok); x = x + pw
  mini(ctx, x, y, pw - 10, 68, "THROTTLE", string.format("%.0f%%", v.throttle), th.accent)

  if not v.ok then U.textc(W / 2, cy - 6, "NO VEHICLE LINK", th.alert, 2) end
end

function D.nav(_, _) return false end   -- read-only cluster

return D
