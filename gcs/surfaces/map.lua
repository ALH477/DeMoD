-- SPDX-License-Identifier: MPL-2.0
-- map.lua — a plan view: vehicle position + heading + a breadcrumb trail.
local M = { name = "MAP", trail = {} }

function M.draw(ctx)
  local th, U, W, H, d = ctx.th, ctx.U, ctx.W, ctx.H, ctx.data
  U.text(24, 58, "MAP", th.accent, 2)
  local x0, y0, w, h = 24, 100, W - 48, H - 180
  U.panel(x0, y0, w, h, th.panel, 255, th.accent)
  -- grid
  for gx = 1, 7 do U.rect(math.floor(x0 + w * gx / 8), y0, 1, h, th.ring, 255) end
  for gy = 1, 5 do U.rect(x0, math.floor(y0 + h * gy / 6), w, 1, th.ring, 255) end

  local px = x0 + U.clamp(d.x or 0.5, 0, 1) * w
  local py = y0 + U.clamp(d.y or 0.5, 0, 1) * h
  local tr = M.trail
  tr[#tr + 1] = { px, py }
  if #tr > 120 then table.remove(tr, 1) end
  for i = 2, #tr do
    dm.draw.thick_line(math.floor(tr[i - 1][1]), math.floor(tr[i - 1][2]),
      math.floor(tr[i][1]), math.floor(tr[i][2]), 2, th.accent2[1], th.accent2[2], th.accent2[3], 160)
  end
  -- vehicle heading arrow
  local a = math.rad((d.yaw or 0) - 90)
  dm.draw.thick_line(math.floor(px), math.floor(py),
    math.floor(px + math.cos(a) * 22), math.floor(py + math.sin(a) * 22),
    3, th.accent[1], th.accent[2], th.accent[3], 255)
  dm.draw.circle(math.floor(px), math.floor(py), 6, th.needle[1], th.needle[2], th.needle[3], 255)
  U.textr(x0 + w - 8, y0 + 8, string.format("%d sats", d.sats or 0), th.dim, 1)
end

return M
