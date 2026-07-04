-- SPDX-License-Identifier: MPL-2.0
-- live.lua — auto-gauges: a bar per telemetry channel.
local L = { name = "LIVE" }

function L.draw(ctx)
  local th, U, W, H, d = ctx.th, ctx.U, ctx.W, ctx.H, ctx.data
  U.text(24, 58, "LIVE TELEMETRY", th.accent, 2)
  local vals = d.vals or {}
  local n = math.max(1, #vals)
  local x, y, gap = 24, 110, 16
  local cw = math.floor((W - 48 - gap * (n - 1)) / n)
  for i = 1, n do
    local v = U.clamp(vals[i] or 0, 0, 1)
    local ph = H - 200
    U.panel(x, y, cw, ph, th.panel, 255, th.accent)
    local barh = ph - 60
    local by = y + 40
    U.rect(x + cw / 2 - 16, by, 32, barh, th.ring, 255)
    local fh = math.floor(barh * v)
    local col = v > 0.9 and th.alert or th.accent
    U.rect(x + cw / 2 - 16, by + barh - fh, 32, fh, col, 255)
    U.textc(x + cw / 2, y + ph - 18, "CH" .. i, th.dim, 1)
    U.textc(x + cw / 2, y + 12, string.format("%.0f%%", v * 100), th.text, 1)
    x = x + cw + gap
  end
  if d.master then U.textr(W - 24, 62, string.format("master %.0f%%", d.master * 100), th.dim, 1) end
end

return L
