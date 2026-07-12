-- SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
--[[ ============================================================================
  midi/clock.lua — transport + tempo, internal or external (pure, dm-free).

  The C parser now forwards MIDI real-time bytes (clock 0xF8 / start 0xFA /
  continue 0xFB / stop 0xFC); the router hands them here via M.feed(kind). At
  24 ppqn, 6 clock ticks = one 16th-note step, so sequencers can stop running
  their own dt accumulator and just subscribe to M.on_step.

  Tempo is derived from wall time between ticks; the host feeds wall time with
  M.update(dt) once per frame (the same dt patches already get in on_update).
  With source = "internal" the same on_step fires off the local bpm instead.

  © 2026 DeMoD LLC. Private.
============================================================================ ]]

local M = {}

local PPQN = 24 -- MIDI clock pulses per quarter note (fixed by the spec)
local TICKS_PER_STEP = PPQN // 4 -- 6 → a 16th-note step

local state = {
	source = "internal", -- "internal" | "external"
	running = false,
	bpm = 120,
	tick = 0, -- external clock pulses since start
	step = 0, -- 16th-note steps elapsed
	wall = 0.0, -- accumulated wall seconds (from update dt)
	last_tick_wall = nil, -- wall time of the previous pulse
	intervals = {}, -- ring of recent pulse intervals (for BPM smoothing)
	int_n = 0,
	acc = 0.0, -- internal-clock step accumulator (seconds)
}

local step_cbs = {}
local transport_cbs = {}

-- subscribe: fn(step_index) each time a 16th-note boundary is crossed
function M.on_step(fn)
	step_cbs[#step_cbs + 1] = fn
end

-- subscribe: fn(kind) for "start" | "stop" | "continue"
function M.on_transport(fn)
	transport_cbs[#transport_cbs + 1] = fn
end

local function fire_step()
	state.step = state.step + 1
	for _, fn in ipairs(step_cbs) do
		fn(state.step)
	end
end

local function fire_transport(kind)
	for _, fn in ipairs(transport_cbs) do
		fn(kind)
	end
end

local function update_bpm()
	-- average the recent inter-pulse intervals → seconds per pulse → BPM.
	local n = #state.intervals
	if n == 0 then
		return
	end
	local sum = 0
	for i = 1, n do
		sum = sum + state.intervals[i]
	end
	local per_pulse = sum / n
	if per_pulse > 0 then
		-- 60 / (per_pulse * PPQN) = quarter notes per minute
		local bpm = 60.0 / (per_pulse * PPQN)
		if bpm > 20 and bpm < 400 then
			state.bpm = bpm
		end
	end
end

-- Router hands real-time transport here. Only meaningful when source=="external".
function M.feed(kind)
	if kind == "start" then
		state.running = true
		state.tick = 0
		state.step = 0
		state.last_tick_wall = nil
		state.intervals = {}
		state.int_n = 0
		fire_transport("start")
	elseif kind == "continue" then
		state.running = true
		fire_transport("continue")
	elseif kind == "stop" then
		state.running = false
		fire_transport("stop")
	elseif kind == "clock" then
		if state.source ~= "external" then
			return
		end
		-- measure interval since the previous pulse for BPM
		if state.last_tick_wall then
			local dt = state.wall - state.last_tick_wall
			if dt > 0 then
				state.int_n = (state.int_n % PPQN) + 1
				state.intervals[state.int_n] = dt
				update_bpm()
			end
		end
		state.last_tick_wall = state.wall
		if state.running then
			state.tick = state.tick + 1
			if state.tick % TICKS_PER_STEP == 0 then
				fire_step()
			end
		end
	end
end

-- Host calls this once per frame with the frame's delta seconds.
function M.update(dt)
	state.wall = state.wall + (dt or 0)
	if state.source == "internal" and state.running then
		local step_dur = 60.0 / state.bpm / 4 -- seconds per 16th note
		state.acc = state.acc + (dt or 0)
		while state.acc >= step_dur do
			state.acc = state.acc - step_dur
			state.tick = state.tick + TICKS_PER_STEP
			fire_step()
		end
	end
end

function M.set_source(src)
	state.source = (src == "external") and "external" or "internal"
end
function M.set_bpm(bpm)
	if tonumber(bpm) then
		state.bpm = tonumber(bpm)
	end
end
function M.start()
	state.running = true
	state.acc = 0
end
function M.stop()
	state.running = false
end
function M.bpm()
	return state.bpm
end
function M.is_running()
	return state.running
end
function M.step_index()
	return state.step
end
function M.source()
	return state.source
end

return M
