-- SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
--[[ ============================================================================
  live-preview.lua — hot-reload harness for developing the Lua UI.

  The desktop SDL window IS the live preview: run any shell/app script under
  this harness and every save reloads it in place (~0.5 s poll). A broken save
  never kills the window — the last good frame stays up with a red error
  overlay until the next good save, and per-frame runtime errors are caught the
  same way.

      scripts/ui-preview.sh                                  # home.lua
      DEMOD_PREVIEW_TARGET=dsp/dsp_studio.lua scripts/ui-preview.sh
      DEMOD_PREVIEW_WATCH=patches.lua,settings.lua scripts/ui-preview.sh

  Semantics + limits (read before trusting a long session):
  - Reload re-runs the target's top level, so its locals re-initialize (state
    resets). Globals the target created are cleared between loads via a _G
    key diff; mutations it made to PRE-EXISTING globals are not restored.
  - C-side state (registered buttons, opened serial ports, …) cannot be reset
    from Lua. If a session accumulates oddities, fall back to
    `scripts/ui-preview.sh --restart`, which relaunches the whole process per
    change and also survives C-level crashes.
  - The harness calls dm.redraw() every update so the overlay/toast stay live;
    the preview loop is therefore free-running (a small CPU cost vs the
    framework's event-driven idle — fine for a dev tool).
  - The target calling dm.quit() (back-exit) quits the process: that IS the
    harness exit.

  © 2026 DeMoD LLC. Private.
============================================================================ ]]

local COL = {
	band = { 64, 10, 18 }, -- error band background
	err = { 255, 76, 106 },
	ok = { 76, 255, 130 },
	bar = { 12, 12, 20 },
	dim = { 106, 106, 134 },
	white = { 232, 232, 240 },
}
local floor = math.floor

local CB = { "on_nav", "on_input", "on_update", "on_draw" }
local TARGET = os.getenv("DEMOD_PREVIEW_TARGET") or "home.lua"

local WATCH = { TARGET }
for tok in (os.getenv("DEMOD_PREVIEW_WATCH") or ""):gmatch("[^,]+") do
	local trimmed = tok:match("^%s*(.-)%s*$")
	if trimmed ~= "" and trimmed ~= TARGET then
		WATCH[#WATCH + 1] = trimmed
	end
end

local current = {} -- last-good target callbacks
local created = {} -- global names the previous load defined (reset set)
local st = {
	err = nil, -- current error string (reload or runtime)
	draw_fails = 0, -- consecutive on_draw failures; stop retrying at 3
	last_reload = "never",
	toast = 0, -- seconds left on the "reloaded" flash
	poll = 0,
	content = {}, -- watched file -> content digest
	loads = 0,
}

local install_harness -- forward decl: re-installs harness callbacks into _G

local function read_file(path)
	local f = io.open(path, "rb")
	if not f then
		return nil
	end
	local s = f:read("*a")
	f:close()
	return s
end

local function digest(s)
	-- Tiny dev-scale files: a real hash is nice, raw compare is a fine fallback.
	if dm.crypto and dm.crypto.sha512 then
		return dm.crypto.sha512(s)
	end
	return s
end

local function load_target()
	-- The target must never see harness callbacks or its own stale globals.
	for _, name in ipairs(CB) do
		_G[name] = nil
	end
	for name in pairs(created) do
		_G[name] = nil
	end

	local before = {}
	for k in pairs(_G) do
		before[k] = true
	end

	local ok, err = pcall(dofile, TARGET) -- catches parse AND top-level runtime errors

	created = {}
	for k in pairs(_G) do
		if not before[k] then
			created[k] = true
		end
	end

	if not ok then
		install_harness() -- the C layer must always find the harness callbacks
		return false, tostring(err)
	end

	local cbs = {}
	local any = false
	for _, name in ipairs(CB) do
		cbs[name] = _G[name]
		if _G[name] then
			any = true
		end
		_G[name] = nil
	end
	install_harness()
	if not any then
		return false, TARGET .. " defines no on_nav/on_input/on_update/on_draw callbacks"
	end

	current = cbs
	st.err, st.draw_fails = nil, 0
	st.last_reload = os.date("%H:%M:%S")
	st.loads = st.loads + 1
	return true
end

local function call(name, ...)
	local fn = current[name]
	if not fn then
		return
	end
	local ok, err = pcall(fn, ...)
	if not ok then
		st.err = name .. ": " .. tostring(err)
		if name == "on_draw" then
			st.draw_fails = st.draw_fails + 1
		end
	elseif name == "on_draw" then
		st.draw_fails = 0
	end
end

local function check_watch()
	for _, path in ipairs(WATCH) do
		local s = read_file(path)
		if s then
			local h = digest(s)
			if st.content[path] == nil then
				st.content[path] = h
			elseif st.content[path] ~= h then
				st.content[path] = h
				local ok, err = load_target()
				if ok then
					st.toast = 2.0
					io.stderr:write("[preview] reloaded " .. TARGET .. " (" .. st.last_reload .. ")\n")
				else
					-- Keep the last-good callbacks; just surface the failure.
					st.err = "reload: " .. tostring(err)
					io.stderr:write("[preview] reload failed: " .. tostring(err) .. "\n")
				end
				return
			end
		end
	end
end

-- ── overlay drawing (8x16 fixed font, ASCII only) ───────────────────────────

local function wrap_text(text, max_chars)
	local lines = {}
	-- collapse newlines; error strings are single-purpose
	text = tostring(text):gsub("[\r\n\t]+", " ")
	while #text > 0 and #lines < 8 do
		lines[#lines + 1] = text:sub(1, max_chars)
		text = text:sub(max_chars + 1)
	end
	return lines
end

local function draw_error_overlay(err)
	local W = dm.width()
	local max_chars = math.max(10, floor((W - 32) / 8))
	local lines = wrap_text(err, max_chars)
	local band_h = 16 + 20 + #lines * 18 + 26

	dm.draw.rect(0, 0, W, band_h, COL.band[1], COL.band[2], COL.band[3], 225)
	dm.draw.rect(0, band_h - 2, W, 2, COL.err[1], COL.err[2], COL.err[3], 200)
	dm.draw.text(16, 12, "PREVIEW ERROR", COL.err[1], COL.err[2], COL.err[3], 255)
	for i, line in ipairs(lines) do
		dm.draw.text(16, 12 + 20 + (i - 1) * 18, line, COL.white[1], COL.white[2], COL.white[3], 235)
	end
	dm.draw.text(16, band_h - 22, "fix + save to reload", COL.dim[1], COL.dim[2], COL.dim[3], 200)
end

local function draw_status_bar()
	local W, H = dm.width(), dm.height()
	local bar_h = 20
	dm.draw.rect(0, H - bar_h, W, bar_h, COL.bar[1], COL.bar[2], COL.bar[3], 215)
	local state = st.err and "ERR" or "OK"
	local c = st.err and COL.err or COL.ok
	local label = "PREVIEW " .. TARGET .. "  reload " .. st.last_reload .. " (" .. st.loads .. ")"
	dm.draw.text(8, H - bar_h + 2, label, COL.dim[1], COL.dim[2], COL.dim[3], 210)
	dm.draw.text(W - #state * 8 - 8, H - bar_h + 2, state, c[1], c[2], c[3], 255)
end

local function draw_toast()
	local W = dm.width()
	local msg = "reloaded"
	local w = #msg * 8 + 24
	local alpha = floor(math.min(1, st.toast / 0.5) * 220)
	dm.draw.rect(floor((W - w) / 2), 8, w, 24, 10, 40, 22, alpha)
	dm.draw.text(floor((W - w) / 2) + 12, 12, msg, COL.ok[1], COL.ok[2], COL.ok[3], alpha)
end

-- ── harness-owned callbacks (the C layer calls these) ────────────────────────
-- Kept in a local table: load_target() nils the callback globals to give the
-- target a clean slate, so the harness must re-install itself after each load
-- (install_harness below) or nothing would ever tick.

local harness = {}

function harness.on_nav(action)
	call("on_nav", action)
end

function harness.on_input(evt, btn, val)
	call("on_input", evt, btn, val)
end

function harness.on_update(dt)
	st.poll = st.poll + (dt or 0)
	if st.poll >= 0.5 then
		st.poll = 0
		check_watch()
	end
	if st.toast > 0 then
		st.toast = math.max(0, st.toast - (dt or 0))
	end
	call("on_update", dt)
	dm.redraw() -- keep the overlay/toast/status alive even when the target idles
end

function harness.on_draw()
	if st.draw_fails < 3 then
		call("on_draw")
	end
	draw_status_bar()
	if st.toast > 0 then
		draw_toast()
	end
	if st.err then
		draw_error_overlay(st.err)
	end
end

install_harness = function()
	for _, name in ipairs(CB) do
		_G[name] = harness[name]
	end
end

-- ── boot ─────────────────────────────────────────────────────────────────────

do
	-- Record initial digests so the first poll doesn't trigger a spurious reload.
	for _, path in ipairs(WATCH) do
		local s = read_file(path)
		if s then
			st.content[path] = digest(s)
		end
	end

	local ok, err = load_target()
	if not ok then
		st.err = "load: " .. tostring(err)
		io.stderr:write("[preview] initial load failed: " .. tostring(err) .. "\n")
	else
		io.stderr:write("[preview] watching " .. table.concat(WATCH, ", ") .. "\n")
	end
	dm.redraw()
end
