-- SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
--[[ ============================================================================
  record.lua — UI-side controller for the take recorder.

  A thin, draw-free wrapper over scripts/demod-record.sh: it shells start/stop via
  dm.exec and reads the recorder's runtime state (pidfile + meta) directly. Shared
  by the DSP Studio RECORD screen and the TERMINUS home REC badge so both see one
  consistent recording state (the recorder runs detached, surviving app switches).
  Copyright (c) 2026 DeMoD LLC. All rights reserved. Private — not for public distribution.
============================================================================ ]]

local M = {}

local BASE = (debug.getinfo(1, "S").source:gsub("^@", "")):match("(.*)/[^/]*$") or "."
local HOME = os.getenv("HOME") or "."
local BIN = os.getenv("DEMOD_RECORD_BIN") or (BASE .. "/scripts/demod-record.sh")
local PLAY_BIN = os.getenv("DEMOD_PLAY_BIN") or (BASE .. "/scripts/demod-play.sh")
local DIR = os.getenv("DEMOD_RECORD_DIR") or (HOME .. "/.local/share/demod/recordings")
local STATE = os.getenv("DEMOD_RECORD_STATE") or (DIR .. "/.state")
local PLAY_STATE = os.getenv("DEMOD_PLAY_STATE") or (DIR .. "/.play")

-- POSIX shell single-quote (see SECURITY.md F-6/F-7).
local function shq(s)
	return "'" .. tostring(s or ""):gsub("'", "'\\''") .. "'"
end

local function read_file(path)
	local f = io.open(path, "r")
	if not f then
		return nil
	end
	local s = f:read("*a")
	f:close()
	return s
end

local function fsize(path)
	if not path or path == "" then
		return 0
	end
	local f = io.open(path, "rb")
	if not f then
		return 0
	end
	local n = f:seek("end")
	f:close()
	return n or 0
end

-- parse a meta file (key=value per line) written by a helper
local function read_meta(dir)
	local t = {}
	local s = read_file(dir .. "/meta")
	if s then
		for k, v in s:gmatch("(%w+)=([^\n]*)") do
			t[k] = v
		end
	end
	return t
end
local function meta()
	return read_meta(STATE)
end

-- liveness for a helper's pidfile via /proc (no fork); pid may be a process-group leader
local function pid_alive(pidfile)
	local pid = read_file(pidfile)
	pid = pid and pid:match("%d+")
	if not pid then
		return false
	end
	local f = io.open("/proc/" .. pid)
	if f then
		f:close()
		return true
	end
	return false
end

-- liveness without forking a process: the pidfile + /proc on Linux
function M.is_recording()
	return pid_alive(STATE .. "/wet.pid")
end

-- { recording, elapsed, take, format, bits, files = {wet,dry}, sizes = {wet,dry} }
function M.status()
	local m = meta()
	local rec = M.is_recording()
	local start = tonumber(m.start) or 0
	return {
		recording = rec,
		elapsed = (rec and start > 0) and (os.time() - start) or 0,
		take = m.take,
		format = m.format,
		bits = m.bits,
		files = { wet = m.wet, dry = (m.dry ~= "" and m.dry or nil) },
		sizes = { wet = fsize(m.wet), dry = fsize(m.dry) },
	}
end

-- cfg: { record_format, record_bitdepth, record_samplerate, record_dual, record_dir }
function M.start(cfg)
	if not dm or not dm.exec then
		return false
	end
	cfg = cfg or {}
	local env = table.concat({
		"DEMOD_RECORD_FORMAT=" .. shq(cfg.record_format or "wav"),
		"DEMOD_RECORD_BITDEPTH=" .. shq(cfg.record_bitdepth or 24),
		"DEMOD_RECORD_SAMPLERATE=" .. shq(cfg.record_samplerate or 48000),
		"DEMOD_RECORD_DUAL=" .. shq((cfg.record_dual == false) and 0 or 1),
		"DEMOD_RECORD_DIR=" .. shq(cfg.record_dir or DIR),
	}, " ")
	-- run via bash so it works whether or not the store copy is +x; the helper
	-- backgrounds ffmpeg itself, so this returns immediately.
	dm.exec(env .. " bash " .. shq(BIN) .. " start")
	return true
end

function M.stop()
	if not dm or not dm.exec then
		return false
	end
	dm.exec("bash " .. shq(BIN) .. " stop")
	return true
end

-- newest-first list of take dirs (for the takes panel). Forks `ls`, so call ON
-- DEMAND (not per frame) and wrap in pcall: a blocking popen read can be EINTR'd
-- when a backgrounded child (ffmpeg / dm.exec) exits.
function M.recent_takes(limit)
	local ok, out = pcall(function()
		local list = {}
		local p = io.popen("ls -1t " .. shq(DIR) .. " 2>/dev/null")
		if p then
			for line in p:lines() do
				if line:match("^take_") then
					list[#list + 1] = line
					if limit and #list >= limit then
						break
					end
				end
			end
			p:close()
		end
		return list
	end)
	return ok and out or {}
end

-- delete a take dir. Guarded to our own "take_*" names (no traversal / arbitrary rm).
function M.delete(take)
	if not dm or not dm.exec or not take or not take:match("^take_[%w_%-]+$") then
		return false
	end
	dm.exec("rm -rf " .. shq(DIR .. "/" .. take))
	return true
end

-- ── take playback (recorder → playback loop; out-of-engine preview) ──────────
function M.is_playing()
	return pid_alive(PLAY_STATE .. "/play.pid")
end

-- { playing, elapsed, take, which, file, dur, loop }
function M.play_status()
	local m = read_meta(PLAY_STATE)
	local playing = M.is_playing()
	local start = tonumber(m.start) or 0
	return {
		playing = playing,
		elapsed = (playing and start > 0) and (os.time() - start) or 0,
		take = m.take,
		which = m.which,
		file = (m.file ~= "" and m.file) or nil,
		dur = tonumber(m.dur),
		loop = m.loop == "1",
	}
end

-- play a take's wet (default) or dry file. `loop` repeats it until stopped.
-- Needs only the take files + a system player — works on any backend (no engine).
function M.play(take, which, loop)
	if not dm or not dm.exec or not take or not take:match("^take_[%w_%-]+$") then
		return false
	end
	local env = table.concat({
		"DEMOD_RECORD_DIR=" .. shq(DIR),
		"DEMOD_PLAY_STATE=" .. shq(PLAY_STATE),
		"DEMOD_PLAY_LOOP=" .. shq(loop and 1 or 0),
	}, " ")
	dm.exec(env .. " bash " .. shq(PLAY_BIN) .. " start " .. shq(take) .. " " .. shq(which or "wet"))
	return true
end

function M.stop_play()
	if not dm or not dm.exec then
		return false
	end
	dm.exec("DEMOD_PLAY_STATE=" .. shq(PLAY_STATE) .. " bash " .. shq(PLAY_BIN) .. " stop")
	return true
end

-- ── multi-instance playback (for the arrangement: several takes layered at once) ──
-- Each instance gets its OWN play-state dir (DIR/.play-<id>), so demod-play.sh — which
-- already reads DEMOD_PLAY_STATE — runs them concurrently with no script change. This is
-- best-effort, out-of-engine layering (not sample-accurate); the take branch swaps for the
-- engine player node when it lands (docs/ENGINE_CONTRACTS.md §2d).
local function instance_state(id)
	return DIR .. "/.play-" .. id
end

function M.play_instance(id, take, which, loop)
	if not dm or not dm.exec then
		return false
	end
	if not (id and id:match("^[%w_%-]+$")) or not (take and take:match("^take_[%w_%-]+$")) then
		return false
	end
	local env = table.concat({
		"DEMOD_RECORD_DIR=" .. shq(DIR),
		"DEMOD_PLAY_STATE=" .. shq(instance_state(id)),
		"DEMOD_PLAY_LOOP=" .. shq(loop and 1 or 0),
	}, " ")
	dm.exec(env .. " bash " .. shq(PLAY_BIN) .. " start " .. shq(take) .. " " .. shq(which or "wet"))
	return true
end

function M.stop_instance(id)
	if not dm or not dm.exec or not (id and id:match("^[%w_%-]+$")) then
		return false
	end
	dm.exec("DEMOD_PLAY_STATE=" .. shq(instance_state(id)) .. " bash " .. shq(PLAY_BIN) .. " stop")
	return true
end

-- stop every layered instance (safety net on song stop / seek / loop-wrap)
function M.stop_all_instances()
	if not dm or not dm.exec then
		return false
	end
	dm.exec(
		"for d in "
			.. shq(DIR)
			.. '/.play-*; do [ -d "$d" ] && DEMOD_PLAY_STATE="$d" bash '
			.. shq(PLAY_BIN)
			.. " stop; done"
	)
	return true
end

M.dir = DIR

return M
