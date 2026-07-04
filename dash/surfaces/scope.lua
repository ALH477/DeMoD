-- SPDX-License-Identifier: MPL-2.0
-- scope.lua — plot the telemetry scope buffer as a waveform.
local S = { name = "SCOPE" }

function S.draw(ctx)
  local th, U, W, H, d = ctx.th, ctx.U, ctx.W, ctx.H, ctx.data
  U.text(24, 58, "SCOPE", th.accent, 2)
  local x0, y0, w, h = 24, 110, W - 48, H - 190
  U.panel(x0, y0, w, h, th.panel, 255, th.accent)
  local cy = y0 + h / 2
  U.rect(x0, math.floor(cy), w, 1, th.ring, 255)   -- zero line
  local s = d.scope or {}
  local n = #s
  if n < 2 then
    U.textc(x0 + w / 2, math.floor(cy) - 8, "no signal", th.dim, 1)
    return
  end
  local px, py
  for i = 1, n do
    local x = x0 + (i - 1) / (n - 1) * w
    local y = cy - U.clamp(s[i], -1, 1) * (h / 2 - 12)
    if i > 1 then
      dm.draw.thick_line(math.floor(px), math.floor(py), math.floor(x), math.floor(y),
        2, th.accent[1], th.accent[2], th.accent[3], 255)
    end
    px, py = x, y
  end
end

return S
