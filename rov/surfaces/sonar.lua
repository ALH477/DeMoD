-- SPDX-License-Identifier: MPL-2.0
-- sonar.lua — the altitude-above-seabed trace.
local S = { name = "SONAR" }

function S.draw(ctx)
  local th, U, W, H, d = ctx.th, ctx.U, ctx.W, ctx.H, ctx.data
  U.text(24, 58, "SEABED / ALTITUDE", th.accent, 2)
  local x0, y0, w, h = 24, 110, W - 48, H - 190
  U.panel(x0, y0, w, h, th.panel, 255, th.accent)
  local s = d.sonar or {}
  local n = #s
  local amax = 20
  U.textr(x0 + w - 8, y0 + 8, string.format("alt %.1f m", d.altitude or 0), th.dim, 1)
  if n < 2 then
    U.textc(x0 + w / 2, y0 + h / 2, "no return", th.dim, 1)
    return
  end
  -- fill the "seabed" below the altitude trace
  local px, py
  for i = 1, n do
    local x = x0 + (i - 1) / (n - 1) * w
    local alt = U.clamp(s[i], 0, amax)
    local y = y0 + (1 - alt / amax) * h    -- higher altitude = higher on screen
    if i > 1 then
      dm.draw.thick_line(math.floor(px), math.floor(py), math.floor(x), math.floor(y),
        2, th.accent2[1], th.accent2[2], th.accent2[3], 255)
    end
    px, py = x, y
  end
end

return S
