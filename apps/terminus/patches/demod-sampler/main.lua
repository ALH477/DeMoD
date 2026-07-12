-- SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
--[[ ============================================================================
  patches/demod-sampler/main.lua — SAMPLER: a 16-pad sample player + library.

  Samples live in a StreamDB-backed library (patches/sampler/sampledb.lua over
  the framework's dm.streamdb_*) — one portable file that rides the marketplace
  USB-C sync like patches. Pads bind to library samples and play through an
  app-level one-shot player (patches/sampler/player.lua). Played by the focus
  field, a live MIDI controller (on_midi → pad), or touch.

  Two screens: PADS (4x4 grid) and LIBRARY (browse / import / delete / assign).
  One focus field spans the pads then the soft-button row, so a bare encoder
  reaches everything.

  Env: DEMOD_SAMPLER_IMPORT=<file> import on the IMPORT action,
       DEMOD_SAMPLER_MIDI=<dev> open a controller (framework also auto-opens
       DEMOD_MIDI), DEMOD_SAMPLER_SCREEN=library, DEMOD_SAMPLER_FOCUS=bar.

  © 2026 DeMoD LLC. Private.
============================================================================ ]]
local HERE = (debug.getinfo(1, "S").source:gsub("^@", "")):match("(.*/)") or "./"
local K = dofile(HERE .. "../games/gamekit.lua")
local SDB = dofile(HERE .. "../sampler/sampledb.lua")
local PLAYER = dofile(HERE .. "../sampler/player.lua")
local Pads = dofile(HERE .. "pads.lua")
local midi = dofile(HERE .. "../../midi/init.lua") -- shared MIDI subsystem (owns on_midi)

local floor, max, min = math.floor, math.max, math.min
local COL = K.COL
local NP = 16 -- pads (4x4)
local COLS = 4
local SAVE_ID = "demod-sampler"

local BTN = { "library", "import", "gaindn", "gainup", "clear" }
local NBTN = #BTN

local pads = Pads.new(NP)
local S = {
	t = 0,
	screen = "pads", -- pads | library
	region = "grid", -- grid | bar
	pad = 1, -- focused pad
	bsel = 1, -- focused soft button
	assign_pad = nil, -- library opened to assign to this pad
	lib = {}, -- cached library list
	lidx = 0, -- library cursor (0 = IMPORT row)
	flash = {},
	msg = nil,
	msg_t = 0,
}

local function set_msg(m)
	S.msg, S.msg_t = m, 2.5
end

-- ── persistence ──────────────────────────────────────────────────────────────
local function persist()
	K.save(SAVE_ID, { pads = pads:serialize() })
end

-- ── library helpers ───────────────────────────────────────────────────────────
local function refresh_lib()
	S.lib = SDB.ok and SDB.list() or {}
	if S.lidx > #S.lib then
		S.lidx = #S.lib
	end
end

local function prune_pads()
	local live = {}
	for _, m in ipairs(S.lib) do
		live[m.id] = true
	end
	pads:prune(live)
end

local function latest_take()
	local home = os.getenv("HOME") or "."
	local dir = (os.getenv("DEMOD_RECORD_DIR")) or (home .. "/.local/share/demod/recordings")
	local p = io.popen("ls -1dt '" .. dir .. "'/take_*/wet.wav 2>/dev/null | head -1")
	if not p then
		return nil
	end
	local line = p:read("*l")
	p:close()
	return (line and #line > 0) and line or nil
end

local function do_import(assign_to)
	if not SDB.ok then
		set_msg("no sample db (needs dm.streamdb)")
		return
	end
	local src = os.getenv("DEMOD_SAMPLER_IMPORT")
	if not (src and #src > 0) then
		src = latest_take()
	end
	if not src then
		set_msg("no source - set DEMOD_SAMPLER_IMPORT or record a take")
		return
	end
	local id, meta = SDB.import(src)
	if id then
		refresh_lib()
		if assign_to then
			pads:assign(assign_to, id, meta.name)
			persist()
		end
		set_msg("imported " .. (meta and meta.name or id))
	else
		set_msg("import failed: " .. tostring(meta))
	end
end

-- ── playback ──────────────────────────────────────────────────────────────────
local function audition(id, gain)
	if not SDB.ok then
		return
	end
	local path = SDB.extract(id)
	if path then
		PLAYER.trig(path, gain or 1.0)
	end
end

local function play_pad(i, vel)
	local p = pads:get(i)
	if not (p and p.id) then
		return
	end
	audition(p.id, p.gain * (vel or 1)) -- vel 0..1 from MIDI; 1 for button/touch
	S.flash[i] = 1.0
end

-- ── BEATS-style library navigation ─────────────────────────────────────────────
local function enter_library(assign_to)
	S.screen = "library"
	S.assign_pad = assign_to
	S.lidx = 0
	refresh_lib()
end

local function nav_library(action)
	local n = #S.lib
	if action == "next" or action == "tab" then
		S.lidx = (S.lidx + 1) % (n + 1)
	elseif action == "prev" or action == "tab_prev" then
		S.lidx = (S.lidx - 1) % (n + 1)
	elseif action == "back" then
		S.screen = "pads"
	elseif action == "activate" then
		if S.lidx == 0 then
			do_import(S.assign_pad)
			if S.assign_pad then
				S.screen = "pads"
			end
		else
			local m = S.lib[S.lidx]
			if S.assign_pad then
				pads:assign(S.assign_pad, m.id, m.name)
				persist()
				set_msg("pad " .. S.assign_pad .. " = " .. m.name)
				S.screen = "pads"
			else
				audition(m.id, 1.0)
			end
		end
	elseif action == "wet" then -- delete
		if S.lidx >= 1 and S.lib[S.lidx] then
			local m = S.lib[S.lidx]
			SDB.delete(m.id)
			refresh_lib()
			prune_pads()
			persist()
			set_msg("deleted " .. m.name)
		end
	end
end

-- ── pads focus ring ────────────────────────────────────────────────────────────
local function ring(dir)
	local total = NP + NBTN
	local cur = (S.region == "grid") and S.pad or (NP + S.bsel)
	local nxt = ((cur - 1 + dir) % total) + 1
	if nxt <= NP then
		S.region, S.pad = "grid", nxt
	else
		S.region, S.bsel = "bar", nxt - NP
	end
end

local function tabmove(dir)
	if S.region == "grid" then
		local np = S.pad + dir * COLS
		if np >= 1 and np <= NP then
			S.pad = np
		else
			S.region, S.bsel = "bar", (dir > 0) and 1 or NBTN
		end
	else
		local nb = S.bsel + dir
		if nb < 1 or nb > NBTN then
			S.region, S.pad = "grid", (dir > 0) and 1 or NP
		else
			S.bsel = nb
		end
	end
end

local function do_activate()
	if S.region == "grid" then
		play_pad(S.pad)
		return
	end
	local id = BTN[S.bsel]
	if id == "library" then
		enter_library(nil)
	elseif id == "import" then
		do_import(S.pad)
	elseif id == "gaindn" then
		pads:bump_gain(S.pad, -0.1)
		persist()
	elseif id == "gainup" then
		pads:bump_gain(S.pad, 0.1)
		persist()
	elseif id == "clear" then
		pads:clear(S.pad)
		persist()
	end
end

local function do_secondary()
	if S.region == "grid" then
		enter_library(S.pad) -- assign a sample to this pad
	end
end

-- ── input funnel ───────────────────────────────────────────────────────────────
local function nav(action)
	if S.screen == "library" then
		nav_library(action)
		dm.redraw()
		return
	end
	if action == "next" then
		ring(1)
	elseif action == "prev" then
		ring(-1)
	elseif action == "tab" then
		tabmove(1)
	elseif action == "tab_prev" then
		tabmove(-1)
	elseif action == "activate" then
		do_activate()
	elseif action == "wet" then
		do_secondary()
	elseif action == "back" then
		if dm.quit then
			dm.quit()
		end
	end
	dm.redraw()
end

function on_nav(action)
	nav(action)
end

-- Live MIDI (notes 36.. → pads, velocity-sensitive) is handled by the shared
-- subsystem and wired up in the boot section. The router owns the global on_midi.

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
		elseif btn == "NAV_PREV" then
			nav("prev")
		elseif btn == "NAV_NEXT" then
			nav("next")
		elseif btn == "NAV_UP" then
			nav("tab_prev")
		elseif btn == "NAV_DOWN" then
			nav("tab")
		end
	end
	dm.redraw()
end

-- ── layout ─────────────────────────────────────────────────────────────────────
local function bucket(W, H)
	if W < 540 or H < 380 then
		return "compact"
	elseif W < 960 then
		return "standard"
	end
	return "wide"
end

local function ell(s, px)
	local n = floor(px / 8)
	if #s <= n then
		return s
	end
	return n <= 1 and "~" or (s:sub(1, n - 1) .. "~")
end

-- ── draw: pads ─────────────────────────────────────────────────────────────────
local function draw_pads(W, H, bk)
	local barh = (bk == "compact") and 38 or 46
	local top = 26
	local gx, gy = 10, top + 4
	local gw, gh = W - 20, H - barh - gy - 6
	local rows = NP / COLS
	local cw, ch = gw / COLS, gh / rows

	for i = 1, NP do
		local col = (i - 1) % COLS
		local row = floor((i - 1) / COLS)
		local x, y = gx + col * cw, gy + row * ch
		local p = pads:get(i)
		local fl = S.flash[i] or 0
		local has = p.id ~= nil
		local base = has and COL.turq or COL.panel
		K.rect(x + 2, y + 2, cw - 4, ch - 4, has and COL.turq or COL.panel, has and floor(40 + fl * 120) or 40)
		K.frame(x + 2, y + 2, cw - 4, ch - 4, has and COL.turq or COL.dim, has and 220 or 110)
		K.text(x + 8, y + 8, string.format("%02d", i), has and COL.turq or COL.dim, 200)
		if has then
			K.text(x + 8, y + floor(ch / 2) - 4, ell(p.name or "?", cw - 16), COL.white, 230)
			K.textr(x + cw - 8, y + ch - 18, string.format("g%.1f", p.gain or 1.0), COL.dim, 160)
		else
			K.textc(x + cw / 2, y + floor(ch / 2) - 4, "[ empty ]", COL.dim, 120)
		end
		if S.region == "grid" and S.pad == i then
			K.frame(x + 1, y + 1, cw - 2, ch - 2, COL.white, 255)
		end
	end

	-- soft-button row
	local by = H - barh
	K.rect(0, by, W, barh, COL.panel, 150)
	K.line(0, by, W, by, COL.turq, 80)
	local bw = W / NBTN
	local labels = { library = "LIBRARY", import = "IMPORT", gaindn = "GAIN-", gainup = "GAIN+", clear = "CLEAR" }
	local lc = { library = COL.violet, import = COL.green, gaindn = COL.white, gainup = COL.white, clear = COL.yellow }
	for i = 1, NBTN do
		local bx = (i - 1) * bw
		K.frame(bx + 2, by + 4, bw - 4, barh - 8, COL.dim, 120)
		K.textc(bx + bw / 2, by + (barh - 12) / 2, labels[BTN[i]], lc[BTN[i]], 230)
		if S.region == "bar" and S.bsel == i then
			K.frame(bx + 1, by + 2, bw - 2, barh - 4, COL.white, 255)
		end
	end
end

-- ── draw: library ──────────────────────────────────────────────────────────────
local function draw_library(W, H, bk)
	local title = S.assign_pad and ("ASSIGN -> PAD " .. string.format("%02d", S.assign_pad)) or "SAMPLE LIBRARY"
	K.textc(floor(W / 2), 30, title, S.assign_pad and COL.green or COL.turq, 230)
	K.textc(floor(W / 2), 46, SDB.ok and SDB.path or "(no sample db)", COL.dim, 120)

	local n = #S.lib
	local listY, rowh = 64, (bk == "compact") and 18 or 22
	local foot = H - 26
	local maxrows = max(3, floor((foot - listY) / rowh))
	local off = (S.lidx >= maxrows) and (S.lidx - maxrows + 1) or 0

	for vis = 0, maxrows - 1 do
		local idx = off + vis
		if idx > n then
			break
		end
		local ry = listY + vis * rowh
		local sel = (idx == S.lidx)
		local label, c
		if idx == 0 then
			label, c = "+  IMPORT FILE  (take / DEMOD_SAMPLER_IMPORT)", COL.green
		else
			local m = S.lib[idx]
			label = string.format("%2d.  %s   %dms %dch", idx, m.name or m.id, m.dur_ms or 0, m.ch or 1)
			c = COL.white
		end
		if sel then
			K.rect(20, ry - 2, W - 40, rowh, COL.panel, 150)
			K.frame(20, ry - 2, W - 40, rowh, c, 200)
		end
		K.text(30, ry + (rowh - 16) / 2, ell(label, W - 60), c, sel and 240 or 180)
	end
	if n == 0 then
		K.textc(floor(W / 2), listY + rowh + 8, "(library empty - IMPORT a take or a WAV)", COL.dim, 140)
	end

	if S.msg and S.msg_t > 0 then
		K.textc(floor(W / 2), foot, S.msg, COL.yellow, 200)
	else
		local hint = S.assign_pad and "[*] assign   [X] delete   [back] cancel"
			or "[*] audition/import   [X] delete   [back] pads"
		K.textc(floor(W / 2), foot, n .. " sample(s)   " .. hint, COL.dim, 150)
	end
end

function on_draw()
	local W, H = dm.width(), dm.height()
	local bk = bucket(W, H)
	K.clear(COL.bg)
	local right = (PLAYER.has and PLAYER.kind or "SILENT")
		.. (SDB.ok and "" or " noDB")
		.. ((S.midi_cue and S.midi_cue > 0) and "  MIDI" or "")
	K.chrome("SAMPLER", right, nil)
	if S.screen == "library" then
		draw_library(W, H, bk)
	else
		-- hint left-aligned after the title (chrome right carries the player mode)
		if S.region == "grid" then
			K.text(84, 5, "[*] play  [X] assign  [back] exit", COL.dim, 150)
		else
			K.text(84, 5, "[*] " .. (BTN[S.bsel] or "") .. "  [back] exit", COL.dim, 150)
		end
		draw_pads(W, H, bk)
		if S.msg and S.msg_t > 0 then
			K.textc(floor(W / 2), 16, S.msg, COL.yellow, 200)
		end
	end
	K.overlay(S.t)
end

function on_update(dt)
	S.t = S.t + dt
	midi.update(dt)
	if S.midi_cue and S.midi_cue > 0 then
		S.midi_cue = max(0, S.midi_cue - dt * 2)
	end
	if S.msg_t > 0 then
		S.msg_t = max(0, S.msg_t - dt)
	end
	for i = 1, NP do
		if S.flash[i] and S.flash[i] > 0 then
			S.flash[i] = max(0, S.flash[i] - dt * 4)
		end
	end
	dm.redraw()
end

-- ── boot ─────────────────────────────────────────────────────────────────────
SDB.init()
PLAYER.init()
do
	local d = K.load(SAVE_ID)
	if type(d.pads) == "string" then
		pads:deserialize(d.pads)
	end
end
refresh_lib()
prune_pads()
do
	if os.getenv("DEMOD_SAMPLER_SCREEN") == "library" then
		enter_library(nil)
	end
	if os.getenv("DEMOD_SAMPLER_FOCUS") == "bar" then
		S.region = "bar"
	end
	-- Live MIDI → pads via the shared subsystem (note→pad map, velocity-sensitive).
	midi.on_note(function(ev)
		if ev.kind ~= "note_on" then
			return
		end
		local pad = midi.map.note_to_pad(ev.note, NP, 36)
		if pad then
			S.midi_cue = 1 -- header MIDI tag (decays in on_update)
			play_pad(pad, ev.vel)
			dm.redraw()
		end
	end)
	local midipath = os.getenv("DEMOD_SAMPLER_MIDI")
	if midipath and #midipath > 0 then
		midi.open(midipath)
	end
end
io.stderr:write("[patch] SAMPLER up (db=" .. tostring(SDB.ok) .. " player=" .. tostring(PLAYER.kind) .. ")\n")
