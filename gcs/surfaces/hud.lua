-- SPDX-License-Identifier: MPL-2.0
-- hud.lua — a primary flight display: artificial horizon + speed/alt/heading.
local H = { name = "HUD" }

function H.draw(ctx)
  local th, U, W, Hh, d = ctx.th, ctx.U, ctx.W, ctx.H, ctx.data
  local cx, cy = math.floor(W / 2), math.floor(Hh / 2 + 6)
  local hy = U.clamp(cy - (d.pitch or 0) * 4, 54, Hh - 44)

  -- sky / ground split at the (pitch-shifted) horizon
  U.rect(0, 40, W, math.floor(hy - 40), th.sky, 255)
  U.rect(0, math.floor(hy), W, math.floor(Hh - 32 - hy), th.ground, 255)

  -- horizon line, rolled
  local roll = math.rad(d.roll or 0)
  local L = W * 0.45
  local dx, dy = math.cos(roll) * L, math.sin(roll) * L
  dm.draw.thick_line(math.floor(cx - dx), math.floor(hy - dy), math.floor(cx + dx), math.floor(hy + dy),
    3, th.needle[1], th.needle[2], th.needle[3], 255)

  -- fixed aircraft reticle
  local a = th.accent2
  dm.draw.thick_line(cx - 44, cy, cx - 12, cy, 3, a[1], a[2], a[3], 255)
  dm.draw.thick_line(cx + 12, cy, cx + 44, cy, 3, a[1], a[2], a[3], 255)
  dm.draw.circle(cx, cy, 4, a[1], a[2], a[3], 255)

  -- speed (left) + alt (right) tapes
  U.panel(24, cy - 26, 140, 52, th.panel, 220, th.accent)
  U.text(30, cy - 44, "SPD m/s", th.dim, 1)
  U.textc(24 + 70, cy - 18, string.format("%.0f", d.speed or 0), th.text, 3)
  U.panel(W - 24 - 140, cy - 26, 140, 52, th.panel, 220, th.accent)
  U.text(W - 24 - 134, cy - 44, "ALT m", th.dim, 1)
  U.textc(W - 24 - 70, cy - 18, string.format("%.0f", d.alt or 0), th.text, 3)

  -- heading + armed/mode
  U.panel(cx - 74, 46, 148, 40, th.panel, 220, th.accent)
  U.textc(cx, 55, string.format("HDG %03.0f", d.yaw or 0), th.text, 2)
  U.textc(cx, Hh - 62, (d.armed and "ARMED" or "DISARMED") .. "   " .. (d.mode or "?"),
    d.armed and th.alert or th.ok, 2)
end

return H
