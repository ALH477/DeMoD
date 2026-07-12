-- SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
--[[ ============================================================================
  dsp/screens/record.lua — take recorder + playback UI.

  Drives the detached recorder (record.lua → scripts/demod-record.sh) and the
  detached player (scripts/demod-play.sh): start/stop a take, list recent takes,
  and PLAY a take back (out-of-engine preview — works on any backend) with a live
  progress bar. The list is a focus field: row 1 is the record transport, the rest
  are takes; activate = record-toggle on row 1, play/stop on a take; hold = delete.
  Recording needs the audio engine (disabled on the stub with a hint); playback only
  needs the take files, so it works everywhere.
  Copyright (c) 2026 DeMoD LLC. All rights reserved. Private — not for public distribution.
============================================================================ ]]

local M = { name = "RECORD", short = "REC" }

local function st(ctx)
	ctx.S.rec = ctx.S.rec or { sel = 1, poll = 0, status = {}, play = {}, takes = {}, loaded = false }
	return ctx.S.rec
end

-- recording needs a real engine; playback only needs the take files
local function rec_ok(ctx)
	return ctx.record ~= nil and (not ctx.dsp.backend_name or ctx.dsp.backend_name() ~= "stub")
end

local function hms(secs)
	secs = math.max(0, math.floor(secs or 0))
	return string.format("%02d:%02d:%02d", secs // 3600, (secs % 3600) // 60, secs % 60)
end

local function mb(bytes)
	return string.format("%.1f MB", (bytes or 0) / 1e6)
end

function M.update(ctx, dt)
	local s = st(ctx)
	if not ctx.record then
		return
	end
	s.poll = (s.poll or 0) + (dt or 0)
	if s.poll > 0.25 then -- ~4 Hz status refresh (cheap: small file reads only)
		s.poll = 0
		local prev = s.status and s.status.recording
		local prevp = s.play and s.play.playing
		s.status = ctx.record.status()
		s.play = ctx.record.play_status()
		-- refresh the take list on demand only (it forks `ls`): once, whenever a take
		-- finishes recording, and when playback stops (a fresh take may have appeared).
		if not s.loaded or (prev and not s.status.recording) or (prevp and not s.play.playing) then
			s.takes = ctx.record.recent_takes(8)
			s.loaded = true
		end
	end
	if (s.status and s.status.recording) or (s.play and s.play.playing) then
		dm.redraw() -- animate the REC pulse / playback progress
	end
end

local function toast(ctx, msg, kind)
	if ctx.toast then
		ctx.toast(msg, kind)
	end
end

function M.nav(ctx, action)
	local s = st(ctx)
	if not ctx.record then
		return false
	end
	local takes = s.takes or {}
	local nrows = 1 + #takes
	local on_take = s.sel >= 2
	local take = on_take and takes[s.sel - 1] or nil

	-- global transport button (Start / footswitch): stop whatever's running, else play the
	-- focused take, else start recording. tab is free here, so it always switches screens.
	if action == "play_stop" then
		if s.status and s.status.recording then
			ctx.record.stop()
			toast(ctx, "Recording stopped", "ok")
		elseif take then
			local ps = s.play or {}
			if ps.playing and ps.take == take then
				ctx.record.stop_play()
			else
				ctx.record.play(take, "wet", ctx.CFG and ctx.CFG.play_loop)
				toast(ctx, "Playing " .. take, "ok")
			end
		elseif rec_ok(ctx) then
			ctx.record.start(ctx.CFG or {})
			toast(ctx, "Recording...", "ok")
		else
			toast(ctx, "Recording needs the audio engine", "warn")
		end
		s.poll = 1
		return true
	end

	if action == "next" then
		s.armed = false
		s.sel = math.min((s.sel or 1) + 1, nrows)
		return true
	elseif action == "prev" then
		s.armed = false
		s.sel = math.max((s.sel or 1) - 1, 1)
		return true
	elseif action == "wet" then -- secondary accelerator: arm delete (take rows, not recording)
		if take and not (s.status and s.status.recording) then
			s.armed = not s.armed
		end
		return true
	elseif action == "back" then
		if s.armed then -- cancel a pending delete
			s.armed = false
			return true
		elseif take and not (s.status and s.status.recording) then
			-- arm delete, keyboard-reachable: back arms, OK confirms, back again cancels.
			-- (wet does the same on gamepad/hardware.) Tab still leaves the screen.
			s.armed = true
			return true
		end
		return false -- transport row / no take → leave the screen
	elseif action == "activate" then
		if s.armed and take then -- confirm pending delete
			if ctx.record.delete(take) then
				toast(ctx, "Deleted " .. take, "warn")
			end
			s.armed, s.loaded = false, false -- force a take-list refresh
			return true
		end
		if s.sel == 1 then -- the record transport row
			if not rec_ok(ctx) then
				toast(ctx, "Recording needs the audio engine", "warn")
				return true
			end
			if s.status and s.status.recording then
				ctx.record.stop()
				toast(ctx, "Recording stopped", "ok")
			else
				ctx.record.start(ctx.CFG or {})
				toast(ctx, "Recording...", "ok")
			end
			s.poll = 1 -- force a status refresh next update
			return true
		elseif take then -- play / stop this take
			local ps = s.play or {}
			if ps.playing and ps.take == take then
				ctx.record.stop_play()
			else
				ctx.record.play(take, "wet", ctx.CFG and ctx.CFG.play_loop)
				toast(ctx, "Playing " .. take, "ok")
			end
			s.poll = 1
			return true
		end
	end
	return false
end

function M.draw(ctx, W, H)
	local U, C = ctx.U, ctx.C
	local s = st(ctx)
	local CFG = ctx.CFG or {}
	local x0 = 20

	U.text(x0, U.HEADER_Y, "RECORD", C.turq, 220)
	local fmt = string.format(
		"%s  %s-bit  %s",
		(CFG.record_format or "wav"):upper(),
		CFG.record_bitdepth or "24",
		(CFG.record_dual == false) and "mono" or "dry+wet"
	)
	U.text_r(W - 20, U.HEADER_Y, fmt, C.dim, 160)
	U.line(x0, 74, W - 20, 74, C.border, 140)

	if not ctx.record then
		U.text_c(W / 2, H / 2 - 8, "RECORDER UNAVAILABLE", C.dim, 180)
		U.footer(W, H, "unavailable on this host")
		return
	end

	local status = s.status or {}
	local play = s.play or {}
	local rec = status.recording

	-- transport banner: REC (pulsing) | PLAY (with progress) | READY
	local cy = 122
	if rec then
		local pulse = 0.5 + 0.5 * math.sin((ctx.S.t or 0) * 4)
		U.circle(x0 + 12, cy, 8, C.red, math.floor(120 + 135 * pulse))
		U.text(x0 + 30, cy - 8, "REC", C.red, 255)
		U.text_r(W - 20, cy - 8, hms(status.elapsed), C.white, 240)
	elseif play.playing then
		U.circle(x0 + 12, cy, 7, C.green, 220)
		U.text(x0 + 30, cy - 8, play.loop and "PLAY [LOOP]" or "PLAY", C.green, 255)
		local pos = play.dur and string.format("%s / %s", hms(play.elapsed), hms(play.dur)) or hms(play.elapsed)
		U.text_r(W - 20, cy - 8, pos, C.white, 240)
	else
		U.circle(x0 + 12, cy, 6, C.border, 180)
		U.text(x0 + 30, cy - 8, "READY", C.dim, 200)
		U.text_r(W - 20, cy - 8, "00:00:00", C.dim, 160)
	end

	-- a single progress/level bar under the banner: record level while recording,
	-- playback position while playing, flat otherwise.
	local by = cy + 16
	local bx, bw = x0 + 56, W - x0 - 56 - 20
	U.text(x0, by, rec and "level" or (play.playing and "pos" or "-"), C.dim, 140)
	U.rect(bx, by, bw, 6, C.border, 150)
	if rec then
		local lv = 0
		for _, v in ipairs((ctx.dsp.meters() or {}).levels or {}) do
			lv = math.max(lv, v)
		end
		U.rect(bx, by, bw * math.min(1, lv), 6, lv > 0.85 and C.red or C.green, 220)
	elseif play.playing and play.dur and play.dur > 0 then
		U.rect(bx, by, bw * math.max(0, math.min(1, play.elapsed / play.dur)), 6, C.green, 220)
	end

	-- live file readout while recording
	local fy = cy + 34
	if rec and status.files then
		if status.files.wet then
			U.text(x0, fy, "wet  " .. mb(status.sizes and status.sizes.wet), C.green, 200)
		end
		if status.files.dry then
			U.text_r(W - 20, fy, "dry  " .. mb(status.sizes and status.sizes.dry), C.green, 180)
		end
	end

	-- ── the focus list: row 1 = record transport, then recent takes ──────────
	local ly = fy + (rec and 22 or 6)
	local rowH = 18
	-- row 1: record transport
	do
		local sel = (s.sel == 1)
		if sel then
			U.rect(x0, ly - 2, W - 40, 16, C.turq, 30)
			U.tline(x0, ly - 2, x0, ly + 14, 3, C.turq, 220)
		end
		local label = rec and "[#] STOP RECORDING" or "[O] START RECORDING"
		local col = rec and C.red or (rec_ok(ctx) and C.white or C.dim)
		U.text(x0 + 8, ly, label, sel and col or (rec and C.red or C.dim), sel and 255 or 170)
		if not rec_ok(ctx) then
			U.text_r(W - 20, ly, "needs engine", C.dim, 130)
		end
	end

	local ty = ly + rowH + 4
	U.text(x0, ty, "RECENT TAKES", C.dim, 150)
	local takes = s.takes or {}
	if #takes == 0 then
		U.text(x0 + 4, ty + 20, "(none yet)", C.dim, 120)
	end
	for i, name in ipairs(takes) do
		local ry = ty + 18 + (i - 1) * rowH
		if ry > H - 44 then
			break
		end
		local sel = (s.sel == i + 1)
		local playing = play.playing and play.take == name
		if sel then
			U.rect(x0, ry - 2, W - 40, 16, (s.armed and C.red or C.turq), s.armed and 50 or 30)
		end
		-- a ">" marker on the take currently playing
		if playing then
			U.text(x0 + 2, ry, ">", C.green, 230)
		end
		local col = sel and (s.armed and C.red or C.white) or (playing and C.green or C.dim)
		U.text(x0 + 14, ry, name, col, sel and 230 or (playing and 210 or 160))
	end

	-- contextual footer
	local hint
	if s.armed and s.sel >= 2 and takes[s.sel - 1] then
		hint = "DELETE " .. takes[s.sel - 1] .. " ?   sel: confirm   back: cancel"
	elseif s.sel == 1 then
		hint = rec and "sel: STOP   turn: list" or "sel: RECORD   turn: list"
	else
		local playing = play.playing and play.take == takes[s.sel - 1]
		hint = (playing and "sel: STOP play" or "sel: PLAY take") .. "   turn: list   back: delete   tab: screen"
	end
	U.footer(W, H, hint)
end

return M
