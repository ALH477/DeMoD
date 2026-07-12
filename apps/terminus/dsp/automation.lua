-- SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
--[[ ============================================================================
  dsp/automation.lua — parameter motion scripts (record / playback), pure-ish.

  A "script" is a timed sequence of param writes — recorded live by capturing every
  set_param while armed, or hand-authored by editing the saved Lua file. Firing a
  script replays the motion in real time; one-shot, or looped. This is distinct from
  presets (which are static snapshots): a script captures MOTION over time.

      script = { name, loop=false, length, trigger = { kind, code },
                 events = { { t, slot, index, value }, ... } }   -- t = seconds from start

  Triggers (kind/code) are matched by the host (dsp_studio) from any input source —
  MIDI note/CC, footswitch, gamepad action, or the on-screen list — all calling fire().

  Persisted as `return { ... }` Lua tables under DEMOD_SCRIPT_DIR (default
  ~/.local/share/demod/scripts), the repo's universal config pattern (dofile to read).
  No dm.*; file/sh I/O only.

  © 2026 DeMoD LLC. Private.
============================================================================ ]]

local M = {}

-- POSIX shell single-quote (dir derives from env; never trust as shell syntax). SECURITY.md F-7.
local function shq(s)
	return "'" .. tostring(s or ""):gsub("'", "'\\''") .. "'"
end

local function script_dir()
	local d = os.getenv("DEMOD_SCRIPT_DIR")
	if d and #d > 0 then
		return d
	end
	local h = os.getenv("HOME") or "/tmp"
	return h .. "/.local/share/demod/scripts"
end

-- sanitize a name into a filename stem ([%w-_] only)
local function stem(name)
	return (tostring(name or "script"):gsub("[^%w%-_]", "_"))
end

M.scripts = {} -- ordered library
M._by_name = {} -- name → script
M.recording = false
local rec = nil -- { script, t0 }
local playing = {} -- active playbacks: { script, t0, idx }

-- ── library ────────────────────────────────────────────────────────────────
function M.list()
	return M.scripts
end
function M.get(name)
	return M._by_name[name]
end

function M.new(name)
	if M._by_name[name] then
		return M._by_name[name]
	end
	local s = { name = name, loop = false, length = 0, events = {}, trigger = nil }
	M.scripts[#M.scripts + 1] = s
	M._by_name[name] = s
	return s
end

function M.delete(name)
	local s = M._by_name[name]
	if not s then
		return
	end
	M.stop(s)
	M._by_name[name] = nil
	for i = #M.scripts, 1, -1 do
		if M.scripts[i] == s then
			table.remove(M.scripts, i)
		end
	end
	os.remove(script_dir() .. "/" .. stem(name) .. ".lua")
end

-- ── record ─────────────────────────────────────────────────────────────────
function M.rec_start(name, now)
	local s = M.new(name)
	s.events = {} -- fresh take overwrites
	rec = { script = s, t0 = now or 0 }
	M.recording = true
	return s
end

-- Called by the host's wrapped set_param while recording.
function M.capture(slot, index, value, now)
	if not (M.recording and rec) then
		return
	end
	rec.script.events[#rec.script.events + 1] = { t = (now or 0) - rec.t0, slot = slot, index = index, value = value }
end

function M.rec_stop()
	if rec then
		local ev = rec.script.events
		rec.script.length = (#ev > 0) and ev[#ev].t or 0
		M.save(rec.script)
	end
	M.recording = false
	local s = rec and rec.script
	rec = nil
	return s
end

-- ── playback ─────────────────────────────────────────────────────────────────
function M.is_playing(script)
	for _, p in ipairs(playing) do
		if p.script == script then
			return true
		end
	end
	return false
end

function M.play(script, now)
	if type(script) == "string" then
		script = M.get(script)
	end
	if not script then
		return
	end
	playing[#playing + 1] = { script = script, t0 = now or 0, idx = 1 }
end

function M.stop(script)
	if type(script) == "string" then
		script = M.get(script)
	end
	for i = #playing, 1, -1 do
		if playing[i].script == script then
			table.remove(playing, i)
		end
	end
end

-- The button gesture: one-shot fires (retriggers from the start); a looped script
-- toggles (press to start the loop, press again to stop).
function M.fire(script, now)
	if type(script) == "string" then
		script = M.get(script)
	end
	if not script then
		return
	end
	if script.loop and M.is_playing(script) then
		M.stop(script)
		return
	end
	M.stop(script) -- clean retrigger
	M.play(script, now)
end

-- Advance all active playbacks; `apply(slot,index,value)` writes the param.
function M.update(now, apply)
	for i = #playing, 1, -1 do
		local p = playing[i]
		local s = p.script
		local elapsed = (now or 0) - p.t0
		while p.idx <= #s.events and s.events[p.idx].t <= elapsed do
			local e = s.events[p.idx]
			apply(e.slot, e.index, e.value)
			p.idx = p.idx + 1
		end
		if p.idx > #s.events then
			if s.loop and s.length > 0 then
				p.t0 = now -- wrap
				p.idx = 1
			else
				table.remove(playing, i) -- one-shot finished
			end
		end
	end
end

-- ── triggers ─────────────────────────────────────────────────────────────────
-- A script carries trigger = { kind, code } (kind "midi" note / "cc" / "foot"). The
-- host funnels discrete control presses here: while assigning, the next press binds;
-- otherwise a matching press fires. Gamepad/key triggers fire by list index instead
-- (the Controller page maps a button → "scriptN"), handled directly in the host.
M.assigning = nil

function M.begin_assign(script)
	if type(script) == "string" then
		script = M.get(script)
	end
	M.assigning = script
end
function M.is_assigning()
	return M.assigning ~= nil
end
function M.cancel_assign()
	M.assigning = nil
end
function M.clear_trigger(script)
	if type(script) == "string" then
		script = M.get(script)
	end
	if script then
		script.trigger = nil
		M.save(script)
	end
end

-- Host hook for a discrete control press. Returns "assigned" | "fired" | nil.
function M.on_control(kind, code, now)
	code = tostring(code)
	if M.assigning then
		M.assigning.trigger = { kind = kind, code = code }
		M.save(M.assigning)
		M.assigning = nil
		return "assigned"
	end
	for _, s in ipairs(M.scripts) do
		if s.trigger and s.trigger.kind == kind and s.trigger.code == code then
			M.fire(s, now)
			return "fired"
		end
	end
	return nil
end

-- ── persistence ──────────────────────────────────────────────────────────────
function M.save(script)
	local dir = script_dir()
	os.execute("mkdir -p " .. shq(dir) .. " 2>/dev/null")
	local f = io.open(dir .. "/" .. stem(script.name) .. ".lua", "w")
	if not f then
		return false
	end
	f:write("-- DeMoD param automation script (generated; hand-editable)\nreturn {\n")
	f:write(string.format("  name = %q,\n", script.name))
	f:write(string.format("  loop = %s,\n", tostring(script.loop and true or false)))
	f:write(string.format("  length = %s,\n", tostring(script.length or 0)))
	if script.trigger then
		f:write(
			string.format(
				"  trigger = { kind = %q, code = %q },\n",
				tostring(script.trigger.kind),
				tostring(script.trigger.code)
			)
		)
	end
	f:write("  events = {\n")
	for _, e in ipairs(script.events) do
		f:write(
			string.format("    { t = %.4f, slot = %d, index = %d, value = %.6g },\n", e.t, e.slot, e.index, e.value)
		)
	end
	f:write("  },\n}\n")
	f:close()
	return true
end

local function adopt(t)
	if type(t) ~= "table" or type(t.name) ~= "string" or type(t.events) ~= "table" then
		return nil
	end
	local s = M.new(t.name)
	s.loop = t.loop and true or false
	s.length = tonumber(t.length) or 0
	s.trigger = (type(t.trigger) == "table") and { kind = t.trigger.kind, code = t.trigger.code } or nil
	s.events = {}
	for _, e in ipairs(t.events) do
		s.events[#s.events + 1] = { t = e.t, slot = e.slot, index = e.index, value = e.value }
	end
	return s
end

-- Load all saved scripts from the script dir (call once at startup).
function M.load_all()
	local dir = script_dir()
	local pipe = io.popen("ls -1 " .. shq(dir) .. " 2>/dev/null")
	if not pipe then
		return
	end
	for line in pipe:lines() do
		if line:match("%.lua$") then
			local ok, t = pcall(dofile, dir .. "/" .. line)
			if ok then
				adopt(t)
			end
		end
	end
	pipe:close()
end

return M
