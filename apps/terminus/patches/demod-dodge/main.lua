-- SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
--[[ ============================================================================
  patches/demod-dodge/main.lua — DODGE: a lane reflex game for TERMINUS.

  Your ship sits at the bottom across N lanes; blocks fall from the top and the
  pace ramps up. Slide between lanes with prev/next and survive — one hit ends
  the run. Score is survival time + blocks dodged. Visual-only, no audio needed.

  Same focus-field model as the shell; `back` aborts to the title, or exits to
  TERMINUS from the title. Shared helpers come from ../games/gamekit.lua.

  © 2026 DeMoD LLC. Private.
============================================================================ ]]
local HERE = (debug.getinfo(1, "S").source:gsub("^@", "")):match("(.*/)") or "./"
local K = dofile(HERE .. "../games/gamekit.lua")

local floor, min, max, random = math.floor, math.min, math.max, math.random
local COL = K.COL

local NLANES = 5
local BLOCK_H = 18
local SELFPLAY = os.getenv("DEMOD_DODGE_SELFPLAY") ~= nil

local SAVE = K.load("demod-dodge")
local best = tonumber(SAVE.best) or 0

local S = {
	state = "title", -- title | play | over
	t = 0,
	elapsed = 0, -- seconds survived this run
	ship = 2, -- lane 0..NLANES-1
	blocks = {}, -- { {lane=, y=, scored=}, ... }
	spawn_t = 0,
	score = 0,
	dodged = 0,
	newbest = false,
	shake = 0,
}

local function reset()
	S.elapsed, S.ship, S.blocks, S.spawn_t = 0, 2, {}, 0
	S.score, S.dodged, S.newbest, S.shake = 0, 0, false, 0
	S.state = "play"
end

local function geom()
	local W, H = dm.width(), dm.height()
	local margin = floor(W * 0.06)
	local laneW = (W - margin * 2) / NLANES
	local shipY = H - 54
	return W, H, margin, laneW, shipY
end

-- ── spawning + collision ─────────────────────────────────────────────────────
local function spawn()
	-- 1–2 blocks, always leaving at least one open lane
	local n = (S.elapsed > 12) and (random(1, 2)) or 1
	local used = {}
	for _ = 1, n do
		local lane
		repeat
			lane = random(0, NLANES - 1)
		until not used[lane]
		used[lane] = true
		S.blocks[#S.blocks + 1] = { lane = lane, y = -BLOCK_H, scored = false }
	end
end

local function game_over()
	S.state = "over"
	if S.score > best then
		best = S.score
		S.newbest = true
		K.save("demod-dodge", { best = best })
	end
end

-- ── input funnel ─────────────────────────────────────────────────────────────
local function nav(action)
	if S.state == "title" then
		if action == "activate" then
			reset()
		elseif action == "back" then
			if dm.quit then
				dm.quit()
			end
		end
	elseif S.state == "play" then
		if action == "prev" then
			S.ship = max(0, S.ship - 1)
		elseif action == "next" then
			S.ship = min(NLANES - 1, S.ship + 1)
		elseif action == "back" then
			S.state = "title"
		end
	elseif S.state == "over" then
		if action == "activate" then
			reset()
		elseif action == "back" then
			S.state = "title"
		end
	end
	dm.redraw()
end

function on_nav(action)
	nav(action)
end
function on_input(evt, btn, val)
	if evt == "ENC_CW" or evt == "ENC_ACCEL_CW" then
		nav("next")
	elseif evt == "ENC_CCW" or evt == "ENC_ACCEL_CCW" then
		nav("prev")
	elseif evt == "DOWN" then
		if btn == "NAV_BACK" then
			nav("back")
		elseif btn == "NAV_OK" or btn == "ENC_PUSH" then
			nav("activate")
		elseif btn == "NAV_PREV" or btn == "NAV_UP" then
			nav("prev")
		elseif btn == "NAV_NEXT" or btn == "NAV_DOWN" then
			nav("next")
		end
	end
	dm.redraw()
end

-- ── update ───────────────────────────────────────────────────────────────────
function on_update(dt)
	S.t = S.t + dt
	if S.shake > 0 then
		S.shake = max(0, S.shake - dt)
	end
	if S.state == "play" then
		local _, H, _, _, shipY = geom()
		S.elapsed = S.elapsed + dt
		S.score = floor(S.elapsed * 10) + S.dodged * 5

		-- self-play: hop to the safest lane (used by the headless smoke test)
		if SELFPLAY then
			local far, bestlane = -1, S.ship
			for lane = 0, NLANES - 1 do
				local nearest = 1e9
				for _, b in ipairs(S.blocks) do
					if b.lane == lane and b.y < shipY then
						nearest = min(nearest, shipY - b.y)
					end
				end
				if nearest > far then
					far, bestlane = nearest, lane
				end
			end
			S.ship = bestlane
		end

		local speed = H * (0.45 + S.elapsed * 0.035)
		speed = min(speed, H * 1.7)

		-- spawn pacing tightens over time
		local interval = max(0.30, 0.95 - S.elapsed * 0.02)
		S.spawn_t = S.spawn_t + dt
		if S.spawn_t >= interval then
			S.spawn_t = S.spawn_t - interval
			spawn()
		end

		-- move blocks, test collision, retire off-screen
		local keep = {}
		for _, b in ipairs(S.blocks) do
			b.y = b.y + speed * dt
			local overlap = (b.y + BLOCK_H >= shipY) and (b.y <= shipY + 14)
			if overlap and b.lane == S.ship then
				S.shake = 0.35
				game_over()
			end
			if b.y > H then
				if not b.scored then
					S.dodged = S.dodged + 1
				end
			else
				keep[#keep + 1] = b
			end
		end
		S.blocks = keep
	end
	dm.redraw()
end

-- ── draw ─────────────────────────────────────────────────────────────────────
local function draw_play()
	local W, H, margin, laneW, shipY = geom()
	local sx = (S.shake > 0) and random(-2, 2) or 0

	-- lane guides
	for i = 0, NLANES do
		local x = margin + i * laneW + sx
		K.line(x, 24, x, H - 16, COL.panel, 90)
	end

	-- blocks
	for _, b in ipairs(S.blocks) do
		local x = margin + b.lane * laneW + sx
		K.rect(x + 3, b.y, laneW - 6, BLOCK_H, COL.red, 70)
		K.rect(x + 3, b.y, laneW - 6, BLOCK_H, COL.red, 200)
		K.frame(x + 3, b.y, laneW - 6, BLOCK_H, COL.white, 40)
	end

	-- ship (a turquoise chevron)
	local cx = margin + (S.ship + 0.5) * laneW + sx
	local hw = laneW * 0.32
	dm.draw.triangle(
		floor(cx),
		floor(shipY - 2),
		floor(cx - hw),
		floor(shipY + 14),
		floor(cx + hw),
		floor(shipY + 14),
		COL.turq[1],
		COL.turq[2],
		COL.turq[3],
		240
	)

	K.chrome("DODGE", string.format("%.1fs", S.elapsed), nil)
	K.text(10, 28, "SCORE " .. S.score, COL.white, 230)
	K.textr(W - 10, 28, "BEST " .. best, COL.dim, 150)
	K.textr(W - 10, H - 12, "[<>] move  [back] quit", COL.dim, 150)
end

local function draw_title()
	local W, H, margin, laneW = geom()
	K.textc(floor(W / 2), floor(H * 0.24), "DODGE", COL.turq, 240)
	K.textc(floor(W / 2), floor(H * 0.24) + 18, "slide between lanes - do not get hit", COL.dim, 160)
	-- a little ship + block motif
	local cy = floor(H * 0.5)
	K.rect(floor(W / 2 - 9), cy - 30, 18, BLOCK_H, COL.red, 200)
	dm.draw.triangle(floor(W / 2), cy, floor(W / 2 - 14), cy + 16, floor(W / 2 + 14), cy + 16, COL.turq[1], COL.turq[2], COL.turq[3], 240)
	K.textc(floor(W / 2), floor(H * 0.72), "BEST  " .. best, COL.yellow, 200)
	K.textc(floor(W / 2), floor(H * 0.86), "[*] start    [back] exit", COL.dim, 170)
end

local function draw_over()
	local W, H = dm.width(), dm.height()
	K.textc(floor(W / 2), floor(H * 0.30), "CRASHED", COL.red, 240)
	if S.newbest then
		K.textc(floor(W / 2), floor(H * 0.30) + 18, "* NEW BEST *", COL.yellow, 230)
	end
	K.textc(floor(W / 2), floor(H * 0.46), "SCORE  " .. S.score, COL.white, 230)
	K.textc(floor(W / 2), floor(H * 0.54), "DODGED " .. S.dodged .. "   " .. string.format("%.1fs", S.elapsed), COL.dim, 190)
	K.textc(floor(W / 2), floor(H * 0.86), "[*] retry    [back] menu", COL.dim, 180)
end

function on_draw()
	K.clear(COL.bg)
	if S.state == "play" then
		draw_play()
	elseif S.state == "over" then
		draw_over()
	else
		draw_title()
	end
	K.overlay(S.t)
end

math.randomseed(os.time())
do
	local st = os.getenv("DEMOD_DODGE_STATE")
	if st == "play" or SELFPLAY then
		reset()
	elseif st == "over" then
		reset()
		S.score, S.dodged, S.elapsed = 880, 40, 21.0
		S.state = "over"
	end
end
io.stderr:write("[patch] DODGE up\n")
