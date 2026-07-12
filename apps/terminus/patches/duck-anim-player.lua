-- SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
-- Duck Dance MIDI Player
-- Reads preprocessed note table and pushes events into midi_input.lua
-- as "secondary" source for the LoFi Keys MkII synth.

local M = {}
local FD -- frame data
local HEREDIR = (debug.getinfo(1, "S").source:gsub("^@", "")):match("(.*/)")

local t = 0
local note_idx = 1
local playing = false
local loop = false
local midi_input -- reference to dsp/midi_input module

-- Active notes for duck animation to read
local active_notes = {}

function M.init()
	if not FD then
		FD = dofile(HEREDIR .. "duck-anim-frames.lua")
	end
	M.reset()
end

function M.reset()
	t = 0
	note_idx = 1
	active_notes = {}
end

function M.set_midi_input(mod)
	midi_input = mod
end

function M.play()
	M.reset()
	playing = true
end

function M.stop()
	playing = false
	M.reset()
	-- Send note-offs for all active notes
	if midi_input then
		for note, _ in pairs(active_notes) do
			midi_input.push_event("secondary", {
				type = "note_off",
				note = note,
				vel = 0,
			})
		end
	end
	active_notes = {}
end

function M.toggle_loop()
	loop = not loop
	return loop
end

function M.is_playing()
	return playing
end

function M.get_active_notes()
	return active_notes
end

-- Call from on_update(dt)
-- Returns active_notes table for duck animation
function M.update(dt)
	if not playing or not FD then
		return active_notes
	end
	t = t + dt

	-- Process MIDI events
	while note_idx <= #FD.midi_notes and t >= FD.midi_notes[note_idx].t do
		local ev = FD.midi_notes[note_idx]
		if ev.k == 1 then -- note_on
			active_notes[ev.n] = { vel = ev.v, age = 0 }

			if midi_input then
				midi_input.push_event("secondary", {
					type = "note_on",
					note = ev.n,
					vel = ev.v,
				})
			end
		else -- note_off
			active_notes[ev.n] = nil

			if midi_input then
				midi_input.push_event("secondary", {
					type = "note_off",
					note = ev.n,
					vel = 0,
				})
			end
		end
		note_idx = note_idx + 1
	end

	-- Age active notes
	for note, info in pairs(active_notes) do
		info.age = (info.age or 0) + dt
	end

	-- End or loop
	if note_idx > #FD.midi_notes then
		if loop then
			t = 0
			note_idx = 1
		else
			playing = false
		end
	end

	return active_notes
end

return M
