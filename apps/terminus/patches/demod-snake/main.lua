-- SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
--[[ ============================================================================
  patches/demod-snake/main.lua — SNAKE: the classic, on the demod-ui engine.

  Relative steering: prev turns LEFT, next turns RIGHT. Eat food to grow; running
  into a wall or yourself ends the run. Movement runs on a FIXED-TIMESTEP
  accumulator (acc += dt; while acc >= STEP do step() end) so the snake advances
  at a constant rate independent of frame-rate / vsync jitter — a clean demo that
  the engine handles deterministic stepping. Zero audio dependency.

  Same focus-field model as the shell; `back` aborts to the title, or exits to
  TERMINUS from the title. Shared helpers come from ../games/gamekit.lua.

  © 2026 DeMoD LLC. Private.
============================================================================ ]]
local HERE = (debug.getinfo(1, "S").source:gsub("^@", "")):match("(.*/)") or "./"
local K = dofile(HERE .. "../games/gamekit.lua")

local floor, max, min, abs, random = math.floor, math.max, math.min, math.abs, math.random
local COL = K.COL
local SELFPLAY = os.getenv("DEMOD_SNAKE_SELFPLAY") ~= nil

local SAVE = K.load("demod-snake")
local best = tonumber(SAVE.best) or 0

local S = {
	state = "title", -- title | play | over
	t = 0,
	acc = 0,
	GW = nil, -- grid set lazily (needs dm.width)
	snake = {},
	dir = { dx = 1, dy = 0 },
	nextdir = { dx = 1, dy = 0 },
	food = { x = 0, y = 0 },
	score = 0,
	newbest = false,
}

-- screen-space (y down) rotations: left = CCW, right = CW
local function rotL(d)
	return { dx = d.dy, dy = -d.dx }
end
local function rotR(d)
	return { dx = -d.dy, dy = d.dx }
end

local function ensure_grid()
	if S.GW then
		return
	end
	local W, H = dm.width(), dm.height()
	local top, bot, margin = 26, 18, 8
	local cell = 14
	S.cell = cell
	S.GW = max(6, floor((W - margin * 2) / cell))
	S.GH = max(6, floor((H - top - bot - margin) / cell))
	S.ox = floor((W - S.GW * cell) / 2)
	S.oy = top + floor(((H - top - bot) - S.GH * cell) / 2)
end

local function place_food()
	-- pick a random empty cell
	for _ = 1, 200 do
		local fx, fy = random(0, S.GW - 1), random(0, S.GH - 1)
		local on = false
		for _, s in ipairs(S.snake) do
			if s.x == fx and s.y == fy then
				on = true
				break
			end
		end
		if not on then
			S.food.x, S.food.y = fx, fy
			return
		end
	end
end

local function init_snake()
	local cx, cy = floor(S.GW / 2), floor(S.GH / 2)
	S.snake = { { x = cx, y = cy }, { x = cx - 1, y = cy }, { x = cx - 2, y = cy } }
	S.dir = { dx = 1, dy = 0 }
	S.nextdir = { dx = 1, dy = 0 }
	place_food()
end

local function reset()
	S.GW = nil -- recompute grid for the current display size
	S.snake = {}
	S.acc = 0
	S.score = 0
	S.newbest = false
	S.state = "play"
end

local function game_over()
	S.state = "over"
	if S.score > best then
		best = S.score
		S.newbest = true
		K.save("demod-snake", { best = best })
	end
end

-- ── one fixed-timestep advance ───────────────────────────────────────────────
local function step()
	-- self-play: pick the safe direction that gets nearest the food
	if SELFPLAY then
		local opts = { S.dir, rotL(S.dir), rotR(S.dir) }
		local bd, bdir = 1e9, S.dir
		for _, d in ipairs(opts) do
			local nx, ny = S.snake[1].x + d.dx, S.snake[1].y + d.dy
			local safe = nx >= 0 and nx < S.GW and ny >= 0 and ny < S.GH
			if safe then
				for i = 1, #S.snake - 1 do
					if S.snake[i].x == nx and S.snake[i].y == ny then
						safe = false
						break
					end
				end
			end
			if safe then
				local dist = abs(nx - S.food.x) + abs(ny - S.food.y)
				if dist < bd then
					bd, bdir = dist, d
				end
			end
		end
		S.nextdir = bdir
	end

	-- forbid a 180° reversal
	if not (S.nextdir.dx == -S.dir.dx and S.nextdir.dy == -S.dir.dy) then
		S.dir = S.nextdir
	end

	local hx = S.snake[1].x + S.dir.dx
	local hy = S.snake[1].y + S.dir.dy
	if hx < 0 or hx >= S.GW or hy < 0 or hy >= S.GH then
		game_over()
		return
	end

	local grow = (hx == S.food.x and hy == S.food.y)
	local body_end = grow and #S.snake or (#S.snake - 1) -- the tail vacates unless growing
	for i = 1, body_end do
		if S.snake[i].x == hx and S.snake[i].y == hy then
			game_over()
			return
		end
	end

	table.insert(S.snake, 1, { x = hx, y = hy })
	if grow then
		S.score = S.score + 10
		place_food()
	else
		table.remove(S.snake)
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
			S.nextdir = rotL(S.dir)
		elseif action == "next" then
			S.nextdir = rotR(S.dir)
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

-- ── update: fixed-timestep accumulator ───────────────────────────────────────
function on_update(dt)
	S.t = S.t + dt
	if S.state == "play" then
		ensure_grid()
		if #S.snake == 0 then
			init_snake()
		end
		local stepdur = max(0.07, 0.16 - #S.snake * 0.003)
		S.acc = S.acc + dt
		while S.acc >= stepdur do
			S.acc = S.acc - stepdur
			if S.state ~= "play" then
				break
			end
			step()
		end
	end
	dm.redraw()
end

-- ── draw ─────────────────────────────────────────────────────────────────────
local function cellrect(gx, gy, c, a, inset)
	inset = inset or 1
	K.rect(S.ox + gx * S.cell + inset, S.oy + gy * S.cell + inset, S.cell - inset * 2, S.cell - inset * 2, c, a)
end

local function draw_play()
	local W, H = dm.width(), dm.height()
	ensure_grid()
	-- board border
	K.frame(S.ox - 1, S.oy - 1, S.GW * S.cell + 1, S.GH * S.cell + 1, COL.panel, 160)
	-- food
	cellrect(S.food.x, S.food.y, COL.yellow, 230, 3)
	cellrect(S.food.x, S.food.y, COL.yellow, 70, 1)
	-- snake
	for i, s in ipairs(S.snake) do
		local c = (i == 1) and COL.turq or COL.green
		cellrect(s.x, s.y, c, i == 1 and 240 or 200)
	end
	K.chrome("SNAKE", "LEN " .. #S.snake, nil)
	K.text(10, 28, "SCORE " .. S.score, COL.white, 230)
	K.textr(W - 10, 28, "BEST " .. best, COL.dim, 150)
	K.textr(W - 10, H - 12, "[<] left  [>] right  [back] quit", COL.dim, 150)
end

local function draw_title()
	local W, H = dm.width(), dm.height()
	K.textc(floor(W / 2), floor(H * 0.26), "SNAKE", COL.green, 240)
	K.textc(floor(W / 2), floor(H * 0.26) + 18, "prev turns left  -  next turns right", COL.dim, 160)
	-- motif
	local cy = floor(H * 0.5)
	for i = 0, 4 do
		K.rect(floor(W / 2 - 40 + i * 16), cy, 14, 14, i == 4 and COL.turq or COL.green, 220)
	end
	K.rect(floor(W / 2 + 48), cy, 12, 12, COL.yellow, 230)
	K.textc(floor(W / 2), floor(H * 0.72), "BEST  " .. best, COL.yellow, 200)
	K.textc(floor(W / 2), floor(H * 0.86), "[*] start    [back] exit", COL.dim, 170)
end

local function draw_over()
	local W, H = dm.width(), dm.height()
	K.textc(floor(W / 2), floor(H * 0.32), "GAME OVER", COL.red, 240)
	if S.newbest then
		K.textc(floor(W / 2), floor(H * 0.32) + 18, "* NEW BEST *", COL.yellow, 230)
	end
	K.textc(floor(W / 2), floor(H * 0.48), "SCORE  " .. S.score, COL.white, 230)
	K.textc(floor(W / 2), floor(H * 0.56), "LENGTH " .. #S.snake, COL.dim, 190)
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
	local st = os.getenv("DEMOD_SNAKE_STATE")
	if st == "play" or SELFPLAY then
		reset()
	elseif st == "over" then
		reset()
		S.score = 120
		S.state = "over"
	end
end
io.stderr:write("[patch] SNAKE up\n")
