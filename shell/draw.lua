-- SPDX-License-Identifier: MPL-2.0
-- draw.lua — shared draw helpers for the DeMoD companion-shell SDK. Only valid
-- inside on_draw (like all dm.draw calls). Exposed to surfaces as ctx.U.
local U = {}

function U.rect(x, y, w, h, col, a)
  dm.draw.rect(x, y, w, h, col[1], col[2], col[3], a or 255)
end

-- A soft "panel": fill + an optional top accent line.
function U.panel(x, y, w, h, col, a, accent)
  dm.draw.rect(x, y, w, h, col[1], col[2], col[3], a or 255)
  if accent then dm.draw.rect(x, y, w, 2, accent[1], accent[2], accent[3], a or 255) end
end

-- NB: dm.draw.text takes scale AFTER the color, so the color must be expanded
-- explicitly (text(..., rgba(col), scale) would truncate multiple returns).
function U.text(x, y, s, col, scale, a)
  dm.draw.text(x, y, s, col[1], col[2], col[3], a or 255, scale or 1)
end

function U.textc(cx, y, s, col, scale, a)
  scale = scale or 1
  local w = dm.draw.text_width(s) * scale
  dm.draw.text(math.floor(cx - w / 2), y, s, col[1], col[2], col[3], a or 255, scale)
end

function U.textr(rx, y, s, col, scale, a)
  scale = scale or 1
  local w = dm.draw.text_width(s) * scale
  dm.draw.text(math.floor(rx - w), y, s, col[1], col[2], col[3], a or 255, scale)
end

-- A sweep-gauge arc from a0..a1 (radians; screen space: 0 = +x, CW as y grows
-- down), filled to `frac` (0..1). Built from thick_line segments (no arc prim).
function U.arc(cx, cy, rad, a0, a1, frac, thick, track, fill, a)
  local segs = 48
  local fillseg = math.floor(segs * math.max(0, math.min(1, frac)) + 0.5)
  local px, py
  for i = 0, segs do
    local t = a0 + (a1 - a0) * (i / segs)
    local x = cx + math.cos(t) * rad
    local y = cy + math.sin(t) * rad
    if i > 0 then
      local col = (i <= fillseg) and fill or track
      dm.draw.thick_line(math.floor(px), math.floor(py), math.floor(x), math.floor(y),
        thick, col[1], col[2], col[3], a or 255)
    end
    px, py = x, y
  end
end

function U.needle(cx, cy, rad, a0, a1, frac, col, a)
  local t = a0 + (a1 - a0) * math.max(0, math.min(1, frac))
  dm.draw.thick_line(cx, cy, math.floor(cx + math.cos(t) * rad), math.floor(cy + math.sin(t) * rad),
    3, col[1], col[2], col[3], a or 255)
end

-- A horizontal bar meter (0..1).
function U.bar(x, y, w, h, frac, track, fill)
  U.rect(x, y, w, h, track, 255)
  local fw = math.floor(w * math.max(0, math.min(1, frac)))
  if fw > 0 then U.rect(x, y, fw, h, fill, 255) end
end

function U.clamp(v, lo, hi) return v < lo and lo or (v > hi and hi or v) end

return U
