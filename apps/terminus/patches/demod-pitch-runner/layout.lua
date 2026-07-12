-- SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
--[[ ============================================================================
  patches/demod-pitch-runner/layout.lua — responsive screen layout (pure).

  No dm.* / no global state: given a screen size it returns integer zone rects so
  the draw code never hardcodes geometry. Reflows by physical size using the house
  compact/standard/wide buckets (home.lua), and is guaranteed to fill the canvas
  and keep zones ordered + on-screen (asserted by layout_selftest.lua).

  Play screen zones (stacked top -> bottom, non-overlapping, within [0,W]x[0,H]):
    header  {y,h}                      chrome bar
    info    {y,h, score_x, best_x}     SCORE (left) / COMBO / BEST (right)
    play    {x,y,w,h}                  framed playfield panel
      hw    {x,y,w,h, hitY, laneW}     highway interior (lanes + hit-line)
    tv      {x,y,w,h}                  target view panel (keyboard / fretboard)
    foot    {y,h,cy}                   tuner strip / hint line (never clipped)

  © 2026 DeMoD LLC. Private.
============================================================================ ]]
local floor, min, max = math.floor, math.min, math.max

local M = {}

function M.bucket(W, H)
	if W < 540 or H < 380 then
		return "compact"
	elseif W < 960 then
		return "standard"
	end
	return "wide"
end

-- centred card rect (menu / over screens)
function M.card(W, H, wf, hf)
	local w = floor(W * wf)
	local h = floor(H * hf)
	return { x = floor((W - w) / 2), y = floor((H - h) / 2), w = w, h = h }
end

-- full play-screen layout
function M.compute(W, H, lanes)
	lanes = max(1, lanes or 6)
	local b = M.bucket(W, H)
	local pad = (b == "compact") and 8 or (b == "standard" and 16 or 28)
	local gap = (b == "compact") and 4 or 8
	local L = { bucket = b, pad = pad, gap = gap, W = W, H = H }

	L.header = { y = 0, h = 22 }

	local infoH = (b == "compact") and 18 or 24
	L.info = {
		y = L.header.h + gap,
		h = infoH,
		score_x = pad + 2,
		best_x = W - pad - 2,
		cx = floor(W / 2),
	}

	local footH = (b == "compact") and 26 or 34
	L.foot = { h = footH, y = H - footH, cy = H - footH + floor(footH / 2) }

	-- split the remaining vertical between the playfield and the target view
	local top = L.info.y + L.info.h + gap
	local bottom = L.foot.y - gap
	local avail = max(40, bottom - top)
	local playFrac = (b == "compact") and 0.58 or 0.62
	local playH = floor(avail * playFrac)
	L.play = { x = pad, y = top, w = W - 2 * pad, h = playH }
	L.tv = { x = pad, y = top + playH + gap, w = W - 2 * pad, h = bottom - (top + playH + gap) }

	-- highway interior inside the playfield panel
	local ip = (b == "compact") and 6 or 12
	local hx, hy = L.play.x + ip, L.play.y + ip
	local hw, hh = L.play.w - 2 * ip, L.play.h - 2 * ip
	-- leave headroom at the top for the NEXT chip
	local headroom = (b == "compact") and 14 or 20
	hy = hy + headroom
	hh = hh - headroom
	L.hw = {
		x = hx,
		y = hy,
		w = hw,
		h = hh,
		laneW = hw / lanes,
		hitY = floor(hy + hh * 0.82),
	}
	L.lanetag_y = L.hw.hitY + 3
	L.nextchip = { cx = floor(W / 2), y = L.play.y + ((b == "compact") and 3 or 6) }

	return L
end

return M
