-- SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
--[[ ============================================================================
  dsp/arrangement.lua — the song / arrangement model + master-transport player.

  A song is TRACK LANES (each a fixed kind: pattern | automation | take) of CLIPS
  placed on a BAR grid. The player is the MASTER TRANSPORT: play() drives the shared
  midi/clock.lua and the song advances off clock.on_step, so it keeps playing across
  every screen and modulation LFOs tempo-sync to it. Driven globally from
  dsp_studio.on_update (after modulation.update), so it never stops when you navigate.

  Per step, for each track:
    · pattern    → fire the active clip's pattern notes to the track's synth slot
                   (via the shared pattern_player; the pattern loops inside its clip),
    · automation → automation.play(script) once on clip entry (global automation.update
                   then replays it),
    · take       → best-effort out-of-engine audio: start a take-player instance on clip
                   entry, stop on exit (NOT sample-accurate / not through the rig FX;
                   swap for the engine player node — ENGINE_CONTRACTS §2d — when it lands).

  Pure / dm-free (file + shell I/O only for persistence). Busted-tested with fake deps.
  Copyright (c) 2026 DeMoD LLC. All rights reserved. Private — not for public distribution.
============================================================================ ]]

local floor = math.floor
local HERE = (debug.getinfo(1, "S").source:gsub("^@", ""):match("(.*/)")) or "./"
local PP = dofile(HERE .. "pattern_player.lua")

local ARRDIR = os.getenv("DEMOD_ARRANGE_DIR") or ((os.getenv("HOME") or ".") .. "/.local/share/demod/songs")
local SEQDIR = os.getenv("DEMOD_SEQ_DIR") or ((os.getenv("HOME") or ".") .. "/.local/share/demod/patterns")
local KINDS = { pattern = true, automation = true, take = true }

local M = {}

-- injected deps (set by attach)
local DSP, MIDI, AUTO, REC
local now_fn = function()
	return 0
end

-- POSIX shell single-quote (SECURITY.md F-6/F-7)
local function shq(s)
	return "'" .. tostring(s or ""):gsub("'", "'\\''") .. "'"
end

-- ── model ─────────────────────────────────────────────────────────────────────
local function default_song()
	return {
		name = "song",
		bpm = 120,
		len_bars = 16,
		bar_steps = 16, -- 4/4, sixteenth-note steps per bar
		loop = { on = false, start_bar = 1, end_bar = 16 },
		tracks = {},
	}
end

local function reset_rt()
	M.rt = { playing = false, song_step = 0, track_state = {}, cache = {} }
end

function M.new_song()
	M.song = default_song()
	reset_rt()
end

local function bar_steps()
	return M.song.bar_steps or 16
end
local function step_of_bar(b)
	return (b - 1) * bar_steps()
end
local function total_steps()
	return M.song.len_bars * bar_steps()
end

local function track_state(ti)
	M.rt.track_state[ti] = M.rt.track_state[ti] or { player = PP.new(), fired_clip = nil, audio_id = nil }
	return M.rt.track_state[ti]
end

-- the clip on a track covering an absolute song step (half-open [start, start+len) in bars)
local function clip_at(track, step)
	for _, clip in ipairs(track.clips or {}) do
		local a = step_of_bar(clip.start_bar)
		if step >= a and step < a + clip.len_bars * bar_steps() then
			return clip
		end
	end
	return nil
end

-- ── pattern source cache (smf → cells[step]={[note]=vel}) ─────────────────────
function M._pattern_cells(source)
	local hit = M.rt.cache[source]
	if hit then
		return hit
	end
	local res
	if MIDI and MIDI.smf then
		local ok, r = MIDI.smf.read_notes(SEQDIR .. "/" .. source)
		if ok then
			res = r
		end
	end
	local cells = {}
	local steps = (res and res.steps) or 16
	if res then
		for _, nt in ipairs(res.notes or {}) do
			for k = 0, math.max(0, (nt.len or 1) - 1) do
				local stp = nt.step + k
				cells[stp] = cells[stp] or {}
				cells[stp][nt.note] = nt.vel or 0.8
			end
		end
	end
	if steps < 1 then
		steps = 16
	end
	hit = { steps = steps, cells = cells }
	M.rt.cache[source] = hit
	return hit
end

-- find an automation script object by name (the library lives in automation.scripts)
local function script_by_name(name)
	for _, sc in ipairs((AUTO and AUTO.scripts) or {}) do
		if sc.name == name then
			return sc
		end
	end
	return nil
end

-- ── take audio instances (best-effort, out-of-engine) ────────────────────────
local function take_id(ti, clip)
	return "arr_t" .. ti .. "_b" .. (clip.start_bar or 0)
end
local function take_start(ti, ts, clip)
	if REC and REC.play_instance then
		ts.audio_id = take_id(ti, clip)
		REC.play_instance(ts.audio_id, clip.source, clip.which or "wet", clip.loop)
	end
end
local function take_stop(ts)
	if ts.audio_id and REC and REC.stop_instance then
		REC.stop_instance(ts.audio_id)
	end
	ts.audio_id = nil
end
local function take_stop_all()
	if REC and REC.stop_all_instances then
		REC.stop_all_instances()
	end
	for _, ts in pairs(M.rt.track_state) do
		ts.audio_id = nil
	end
end

-- release every track's notes (+ optionally clear fired_clip so clips re-trigger)
local function release_all(clear_fired)
	for ti = 1, #M.song.tracks do
		local ts = track_state(ti)
		ts.player:release(DSP)
		if clear_fired then
			ts.fired_clip = nil
		end
	end
end

-- ── the step engine (fires from clock.on_step via midi.update) ────────────────
local function fire_tracks(step)
	for ti = 1, #M.song.tracks do
		local track = M.song.tracks[ti]
		local ts = track_state(ti)
		if track.mute then
			ts.player:release(DSP)
			take_stop(ts)
			ts.fired_clip = nil
		else
			local clip = clip_at(track, step)
			if track.kind == "pattern" then
				if clip then
					local pat = M._pattern_cells(clip.source)
					local local_step = ((step - step_of_bar(clip.start_bar)) % pat.steps) + 1
					ts.player:step(DSP, track.target, pat.cells, local_step)
				else
					ts.player:release(DSP)
				end
			elseif track.kind == "automation" then
				if clip and ts.fired_clip ~= clip then
					local sc = script_by_name(clip.source)
					if sc and AUTO and AUTO.play then
						AUTO.play(sc, now_fn())
					end
					ts.fired_clip = clip
				elseif not clip then
					ts.fired_clip = nil
				end
			elseif track.kind == "take" then
				if clip and ts.fired_clip ~= clip then
					take_start(ti, ts, clip)
					ts.fired_clip = clip
				elseif not clip and ts.fired_clip then
					take_stop(ts)
					ts.fired_clip = nil
				end
			end
		end
	end
end

local function wrap_to(target)
	M.rt.song_step = target
	release_all(true)
	take_stop_all()
end

-- one 16th-note step; subscribed to midi.clock.on_step at attach. Fires the CURRENT
-- song_step then advances, so play()/seek() set song_step to the first step to play.
function M._on_step()
	local rt = M.rt
	if not (rt and rt.playing) then
		return
	end
	local loop = M.song.loop
	if loop and loop.on and rt.song_step >= step_of_bar(loop.end_bar + 1) then
		wrap_to(step_of_bar(loop.start_bar))
	elseif not (loop and loop.on) and rt.song_step >= total_steps() then
		M.stop()
		return
	end
	fire_tracks(rt.song_step)
	rt.song_step = rt.song_step + 1
end

-- ── transport ─────────────────────────────────────────────────────────────────
function M.play()
	if not M.song then
		M.new_song()
	end
	local rt = M.rt
	if rt.song_step >= total_steps() then
		rt.song_step = 0 -- restart a finished song from the top
	end
	rt.playing = true
	local clk = MIDI and MIDI.clock
	if clk and clk.source() ~= "external" then -- master transport (external clock owns itself)
		clk.set_source("internal")
		clk.set_bpm(M.song.bpm)
		clk.start()
	end
end

function M.stop()
	local rt = M.rt
	if not rt then
		return
	end
	rt.playing = false
	for ti = 1, #M.song.tracks do
		local ts = track_state(ti)
		ts.player:panic(DSP, M.song.tracks[ti].target)
		ts.fired_clip = nil
	end
	take_stop_all()
	local clk = MIDI and MIDI.clock
	if clk and clk.source() ~= "external" then
		clk.stop()
	end
end

function M.seek(bar)
	M.rt.song_step = math.max(0, step_of_bar(math.max(1, bar or 1)))
	release_all(true)
	take_stop_all()
end

function M.is_playing()
	return M.rt and M.rt.playing
end
function M.song_bar()
	return floor((M.rt and M.rt.song_step or 0) / bar_steps()) + 1
end
function M.song_step()
	return M.rt and M.rt.song_step or 0
end

-- thin per-frame housekeeping (stepping rides clock.on_step; here for API symmetry)
function M.update(_) end

-- ── editing ─────────────────────────────────────────────────────────────────
function M.add_track(kind, name, target)
	kind = KINDS[kind] and kind or "pattern"
	M.song.tracks[#M.song.tracks + 1] =
		{ kind = kind, name = name or kind:upper(), target = target, mute = false, clips = {} }
	return #M.song.tracks
end

function M.remove_track(ti)
	if not M.song.tracks[ti] then
		return
	end
	-- panic everything (indices shift) then drop the track + rebuild runtime state
	for i = 1, #M.song.tracks do
		track_state(i).player:panic(DSP, M.song.tracks[i].target)
	end
	take_stop_all()
	table.remove(M.song.tracks, ti)
	M.rt.track_state = {}
end

function M.place_clip(ti, source, start_bar, len_bars)
	local t = M.song.tracks[ti]
	if not t then
		return
	end
	local clip = { source = source, start_bar = math.max(1, start_bar or 1), len_bars = math.max(1, len_bars or 1) }
	if t.kind == "take" then
		clip.which, clip.loop = "wet", false
	end
	t.clips[#t.clips + 1] = clip
	return clip
end

function M.remove_clip(ti, clip)
	local t = M.song.tracks[ti]
	if not t then
		return
	end
	for i, c in ipairs(t.clips) do
		if c == clip then
			table.remove(t.clips, i)
			return
		end
	end
end

function M.set_clip_source(_, clip, source)
	clip.source = source
	M.rt.cache[source] = nil -- bust the pattern cache for the new source
end

function M.reload_patterns()
	M.rt.cache = {}
end

function M.set_loop(on, a, b)
	M.song.loop = { on = on and true or false, start_bar = a or 1, end_bar = b or M.song.len_bars }
end
function M.set_bpm(b)
	M.song.bpm = math.max(20, math.min(400, math.floor(b)))
	local clk = MIDI and MIDI.clock
	if clk then
		clk.set_bpm(M.song.bpm)
	end
end
function M.set_len(bars)
	M.song.len_bars = math.max(1, math.floor(bars))
end

-- ── persistence (Option B: per-song hand-editable Lua under DEMOD_ARRANGE_DIR) ─
local function q(s)
	return string.format("%q", tostring(s))
end

local function serialize(song)
	local b = { "return {" }
	b[#b + 1] = string.format(
		"  name=%s, bpm=%d, len_bars=%d, bar_steps=%d,",
		q(song.name),
		song.bpm,
		song.len_bars,
		song.bar_steps or 16
	)
	local lp = song.loop or {}
	b[#b + 1] = string.format(
		"  loop={ on=%s, start_bar=%d, end_bar=%d },",
		tostring(lp.on and true or false),
		lp.start_bar or 1,
		lp.end_bar or song.len_bars
	)
	b[#b + 1] = "  tracks={"
	for _, t in ipairs(song.tracks) do
		b[#b + 1] = string.format(
			"    { kind=%s, name=%s, target=%s, mute=%s, clips={",
			q(t.kind),
			q(t.name or ""),
			t.target and tostring(t.target) or "nil",
			tostring(t.mute and true or false)
		)
		for _, c in ipairs(t.clips or {}) do
			b[#b + 1] = string.format(
				"      { source=%s, start_bar=%d, len_bars=%d%s%s },",
				q(c.source),
				c.start_bar,
				c.len_bars,
				c.which and (", which=" .. q(c.which)) or "",
				(c.loop ~= nil) and (", loop=" .. tostring(c.loop and true or false)) or ""
			)
		end
		b[#b + 1] = "    } },"
	end
	b[#b + 1] = "  },"
	b[#b + 1] = "}"
	return table.concat(b, "\n") .. "\n"
end

-- validate/coerce a loaded table into a clean song (drop malformed clips, clamp kinds)
local function adopt(t)
	local s = default_song()
	s.name = tostring(t.name or "song")
	s.bpm = math.max(20, math.min(400, tonumber(t.bpm) or 120))
	s.len_bars = math.max(1, math.floor(tonumber(t.len_bars) or 16))
	s.bar_steps = math.max(1, math.floor(tonumber(t.bar_steps) or 16))
	local lp = t.loop or {}
	s.loop = {
		on = lp.on and true or false,
		start_bar = math.max(1, math.floor(tonumber(lp.start_bar) or 1)),
		end_bar = math.max(1, math.floor(tonumber(lp.end_bar) or s.len_bars)),
	}
	for _, t0 in ipairs(t.tracks or {}) do
		if KINDS[t0.kind] then
			local tr = {
				kind = t0.kind,
				name = tostring(t0.name or t0.kind),
				target = tonumber(t0.target),
				mute = t0.mute and true or false,
				clips = {},
			}
			for _, c in ipairs(t0.clips or {}) do
				if c.source and tonumber(c.start_bar) and tonumber(c.len_bars) then
					tr.clips[#tr.clips + 1] = {
						source = tostring(c.source),
						start_bar = math.max(1, math.floor(c.start_bar)),
						len_bars = math.max(1, math.floor(c.len_bars)),
						which = c.which,
						loop = c.loop,
					}
				end
			end
			s.tracks[#s.tracks + 1] = tr
		end
	end
	return s
end

function M.save(name)
	os.execute("mkdir -p " .. shq(ARRDIR) .. " 2>/dev/null")
	name = (name and name ~= "" and name) or ("song_" .. os.date("%Y%m%d_%H%M%S"))
	local path = ARRDIR .. "/" .. name .. ".lua"
	local f = io.open(path, "w")
	if not f then
		return false
	end
	f:write(serialize(M.song))
	f:close()
	return true, name
end

function M.load(path)
	local ok, t = pcall(dofile, path)
	if not ok or type(t) ~= "table" then
		return false
	end
	M.song = adopt(t)
	reset_rt()
	return true
end

function M.list()
	local out = {}
	local ok, pipe = pcall(io.popen, "ls -1t " .. shq(ARRDIR) .. "/*.lua 2>/dev/null")
	if ok and pipe then
		for line in pipe:lines() do
			local n = line:match("([^/]+)%.lua$")
			if n then
				out[#out + 1] = n
			end
		end
		pipe:close()
	end
	return out
end

function M.load_recent()
	local ok, pipe = pcall(io.popen, "ls -1t " .. shq(ARRDIR) .. "/*.lua 2>/dev/null")
	local path
	if ok and pipe then
		path = pipe:read("*l")
		pipe:close()
	end
	if path and path ~= "" then
		return M.load(path)
	end
	return false
end

M.dir = ARRDIR

-- ── lifecycle ─────────────────────────────────────────────────────────────────
function M.attach(dsp, midi, automation, record)
	DSP, MIDI, AUTO, REC = dsp, midi, automation, record
	if not M.song then
		M.new_song()
	end
	if MIDI and MIDI.clock and MIDI.clock.on_step then
		MIDI.clock.on_step(function(idx)
			M._on_step(idx)
		end)
	end
end

function M.set_now(fn)
	now_fn = fn or now_fn
end

M.new_song() -- a valid empty song until attach/load
return M
