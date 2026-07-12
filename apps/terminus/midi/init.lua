-- SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
--[[ ============================================================================
  midi/init.lua — the shared MIDI router. One global on_midi, many subscribers.

  This is the "separated" core of the MIDI subsystem. The C framework calls the
  single Lua global on_midi(status,d1,d2); THIS module owns it, decodes each
  message into a structured event, applies the channel filter + velocity policy,
  routes transport bytes to clock.lua and CCs to learn.lua, and dispatches to
  every subscriber. Patches/apps stop defining their own on_midi and instead:

      local midi = dofile(HERE .. "../../midi/init.lua")   -- (path varies)
      midi.on_note(function(ev) ... end)                   -- ev.kind on/off
      midi.on_cc(function(ev) ... end)
      -- once per frame, in on_update(dt):
      midi.update(dt)

  Degrades gracefully when the dm.midi_* bindings are absent (older host, headless
  with no device): subscriptions still work — events just won't arrive — and the
  device/output calls no-op. Mirrors steam.lua's optional-binding wrap.

  Event shape:
    { ch=1..16, kind="note_on"|"note_off"|"cc"|"pitch"|"aftertouch"|
                     "program"|"clock"|"start"|"stop"|"continue",
      note=, vel=0..1, vel127=, cc=, value=0..127, valuef=0..1, a=d1, b=d2 }

  © 2026 DeMoD LLC. Private.
============================================================================ ]]

local HERE = (debug.getinfo(1, "S").source:gsub("^@", "")):match("(.*/)") or "./"
local map = dofile(HERE .. "map.lua")
local clock = dofile(HERE .. "clock.lua")
local learn = dofile(HERE .. "learn.lua")
local smf = dofile(HERE .. "smf.lua")

local M = { map = map, clock = clock, learn = learn, smf = smf }

local DM = (type(rawget(_G, "dm")) == "table") and dm or nil
local function has(fn)
	return DM and type(DM[fn]) == "function"
end

-- ── config ─────────────────────────────────────────────────────────────────
local cfg = {
	channel = 0, -- 0 = omni, else 1..16
	vel_mode = "as_played", -- "as_played" | "fixed"
	vel_fixed = 0.8,
	preferred = nil, -- device id we want open (for hotplug reconnect)
	thru = false, -- echo input to the MIDI output (controller passthrough)
}

-- Global config also arrives via env so the shell can push it into the separate
-- patch processes it launches (terminus/dm.exec set these): DEMOD_MIDI_CHANNEL
-- (0=omni|1..16), DEMOD_MIDI_CLOCK (internal|external), DEMOD_MIDI_VELOCITY
-- (as_played|fixed). Settings → MIDI configures the live process directly.
do
	local ch = tonumber(os.getenv("DEMOD_MIDI_CHANNEL") or "")
	if ch then
		cfg.channel = ch
	end
	if (os.getenv("DEMOD_MIDI_CLOCK") or "") == "external" then
		clock.set_source("external")
	end
	local vm = os.getenv("DEMOD_MIDI_VELOCITY")
	if vm == "fixed" or vm == "as_played" then
		cfg.vel_mode = vm
	end
end

function M.set_channel(ch)
	cfg.channel = tonumber(ch) or 0
end
function M.set_velocity(mode, fixed)
	cfg.vel_mode = (mode == "fixed") and "fixed" or "as_played"
	if fixed then
		cfg.vel_fixed = fixed
	end
end
function M.set_thru(on)
	cfg.thru = on and true or false
end
function M.note_name(n)
	return map.note_name(n)
end

-- ── subscribers ─────────────────────────────────────────────────────────────
-- subs[kind] = { fn, fn, ... }; kind "*" receives every event.
local subs = {}
local function add(kind, fn)
	subs[kind] = subs[kind] or {}
	local list = subs[kind]
	list[#list + 1] = fn
	return { kind = kind, fn = fn }
end

function M.subscribe(kind, fn)
	return add(kind, fn)
end
function M.on_note(fn) -- both note_on and note_off
	add("note_on", fn)
	add("note_off", fn)
end
function M.on_cc(fn)
	add("cc", fn)
end
function M.on_any(fn)
	add("*", fn)
end
function M.unsubscribe(handle)
	if not (handle and subs[handle.kind]) then
		return
	end
	local list = subs[handle.kind]
	for i = #list, 1, -1 do
		if list[i] == handle.fn then
			table.remove(list, i)
		end
	end
end

-- ── telemetry (for the UI: activity badge, last-event readout) ──────────────
M._act = 0 -- activity 0..1, decays in update()
M._last = nil -- { kind, label, t } of the last non-clock event
M._open = {} -- device id → true (tracked so connected_label can name them)

local function label_of(ev)
	if ev.kind == "note_on" then
		return map.note_name(ev.note) .. " v" .. (ev.vel127 or 0)
	elseif ev.kind == "note_off" then
		return map.note_name(ev.note) .. " off"
	elseif ev.kind == "cc" then
		return "CC" .. ev.cc .. "=" .. ev.value
	elseif ev.kind == "pitch" then
		return "bend " .. (ev.value or 0)
	elseif ev.kind == "program" then
		return "prog " .. (ev.value or 0)
	end
	return ev.kind
end

local function emit(ev)
	M._act = 1
	if ev.kind ~= "clock" then
		M._last = { kind = ev.kind, label = label_of(ev), t = 0 }
	end
	local list = subs[ev.kind]
	if list then
		for _, fn in ipairs(list) do
			fn(ev)
		end
	end
	local any = subs["*"]
	if any then
		for _, fn in ipairs(any) do
			fn(ev)
		end
	end
end

-- ── decode ──────────────────────────────────────────────────────────────────
-- The single global the C layer calls. Owns dispatch for the whole process.
local function dispatch(status, d1, d2)
	-- MIDI thru: echo the raw message to the output before any filtering (a true
	-- passthrough). No-op without an output device.
	if cfg.thru then
		M.send(status, d1, d2)
	end
	-- transport / real-time (channel-less): always handled, never channel-filtered.
	if status >= 0xF8 then
		local kind = (status == 0xF8 and "clock")
			or (status == 0xFA and "start")
			or (status == 0xFB and "continue")
			or (status == 0xFC and "stop")
		if kind then
			clock.feed(kind)
			emit({ kind = kind, a = status, b = 0 })
		end
		return
	end

	local hi = status & 0xF0
	local ch = (status & 0x0F) + 1
	if cfg.channel ~= 0 and ch ~= cfg.channel then
		return -- channel filter (transport already handled above)
	end

	if hi == 0x90 and d2 > 0 then
		emit({
			kind = "note_on",
			ch = ch,
			note = d1,
			vel = map.velocity(d2, cfg.vel_mode, cfg.vel_fixed),
			vel127 = d2,
			a = d1,
			b = d2,
		})
	elseif hi == 0x80 or (hi == 0x90 and d2 == 0) then
		emit({ kind = "note_off", ch = ch, note = d1, vel = 0, vel127 = 0, a = d1, b = d2 })
	elseif hi == 0xB0 then
		local ev = { kind = "cc", ch = ch, cc = d1, value = d2, valuef = d2 / 127, a = d1, b = d2 }
		learn.handle_cc(ev)
		emit(ev)
	elseif hi == 0xE0 then
		local bend = (d1 | (d2 << 7)) - 8192 -- -8192..8191
		emit({ kind = "pitch", ch = ch, value = bend, valuef = bend / 8192, a = d1, b = d2 })
	elseif hi == 0xA0 then
		emit({ kind = "aftertouch", ch = ch, note = d1, value = d2, a = d1, b = d2 })
	elseif hi == 0xD0 then
		emit({ kind = "aftertouch", ch = ch, value = d1, a = d1, b = d2 })
	elseif hi == 0xC0 then
		emit({ kind = "program", ch = ch, value = d1, a = d1, b = d2 })
	end
end

-- Install the global. Anything previously assigned to on_midi is replaced — by
-- design there is exactly one router. (Patches must migrate to subscribe().)
_G.on_midi = dispatch
M.dispatch = dispatch -- exposed for tests / manual feeding

-- ── devices ─────────────────────────────────────────────────────────────────
function M.devices()
	if has("midi_list") then
		return DM.midi_list() or {}
	end
	return {}
end
function M.open(id)
	if has("midi_open") and id and id ~= "" then
		local ok = DM.midi_open(id) and true or false
		if ok then
			M._open[id] = true
		end
		return ok
	end
	return false
end
function M.close(id)
	if has("midi_close") then
		DM.midi_close(id)
	end
	if id then
		M._open[id] = nil
	end
end
function M.close_all()
	if has("midi_close") then
		DM.midi_close()
	end
	M._open = {}
end

-- Select a single preferred input: close everything else, open this one, and
-- remember it so update() can reconnect it after a hotplug. id "" / nil = none.
function M.select_device(id)
	cfg.preferred = (id ~= "" and id) or nil
	M.close_all()
	if cfg.preferred then
		M.open(cfg.preferred)
	end
end

-- ── output (controller feedback) ─────────────────────────────────────────────
function M.open_output(id)
	if has("midi_out_open") and id and id ~= "" then
		return DM.midi_out_open(id) and true or false
	end
	return false
end
function M.send(status, d1, d2)
	if has("midi_send") then
		DM.midi_send(status, d1 or 0, d2 or 0)
	end
end
function M.note_out(ch, note, vel) -- convenience: note on (vel>0) / off
	local st = ((vel and vel > 0) and 0x90 or 0x80) | ((ch or 1) - 1)
	M.send(st, note, vel or 0)
end

-- ── telemetry accessors (UI reads these for the activity badge / status rows) ─
function M.activity()
	return M._act or 0
end
function M.last_label()
	return (M._last and M._last.label) or "-"
end
function M.bpm()
	return clock.bpm()
end
function M.clock_source()
	return clock.source()
end
-- Friendly label of the currently-open input(s), or "auto"/"(none)".
function M.connected_label()
	local names = {}
	for _, d in ipairs(M.devices()) do
		if M._open[d.id] then
			names[#names + 1] = d.name or d.id
		end
	end
	if #names > 0 then
		return table.concat(names, ", ")
	end
	local env = os.getenv("DEMOD_MIDI")
	return (env and #env > 0) and "auto" or "(none)"
end

-- ── per-frame ────────────────────────────────────────────────────────────────
local rescan_acc = 0
function M.update(dt)
	clock.update(dt)
	-- decay activity toward 0 (~1.5s tail) + age the last-event readout
	if M._act > 0 then
		M._act = math.max(0, M._act - (dt or 0) / 1.5)
	end
	if M._last then
		M._last.t = M._last.t + (dt or 0)
	end
	-- light hotplug: if a preferred device is set but not currently present-and-open,
	-- try to (re)open it when it reappears. Rescan ~twice a second, not every frame.
	if cfg.preferred and has("midi_list") then
		rescan_acc = rescan_acc + (dt or 0)
		if rescan_acc >= 0.5 then
			rescan_acc = 0
			for _, d in ipairs(M.devices()) do
				if d.id == cfg.preferred then
					M.open(cfg.preferred) -- idempotent in C (dedup by path)
					break
				end
			end
		end
	end
end

return M
