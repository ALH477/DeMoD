-- SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
-- Duck Dance Animation Module
-- Drives sprite + oscilloscope waves from preprocessed frame/MIDI data.
-- Usage:
--   local duck = dofile(HERE .. "/duck-anim.lua")
--   duck.init()
--   -- in on_update(dt):
--   duck.update(dt, active_notes_table)
--   -- in on_draw():
--   duck.draw(x, y, w, h)

local M = {}
local FD -- frame data (loaded lazily)
local bin -- raw binary blob
local t = 0
local frame_idx = 1
local paused = false

local notes = {} -- active notes {note -> {vel, age}}
local bpm = 160
local beat_t = 0

local COL = { turq = { 0, 245, 212 }, violet = { 139, 92, 246 }, white = { 232, 232, 240 } }

local HEREDIR = (debug.getinfo(1, "S").source:gsub("^@", "")):match("(.*/)")

function M.init()
	if not FD then
		FD = dofile(HEREDIR .. "duck-anim-frames.lua")
		bpm = FD.bpm or 160
		local binpath = HEREDIR .. "duck-anim-frames.bin"
		local f = io.open(binpath, "rb")
		if f then
			bin = f:read("*all")
			f:close()
		end
	end
	M.reset()
end

function M.reset()
	t = 0
	frame_idx = 1
	beat_t = 0
	notes = {}
end

function M.play()
	paused = false
	M.reset()
end

function M.stop()
	paused = true
	M.reset()
end

function M.pause()
	paused = true
end

function M.resume()
	paused = false
end

-- Call from on_update(dt)
-- active_notes: { [note_num] = { vel = 0-1, age = seconds } }
function M.update(dt, active_notes)
	if paused then
		return
	end
	t = t + dt
	beat_t = beat_t + dt

	if active_notes then
		notes = active_notes
	end

	-- Advance frame by timing table
	if FD and FD.frame_map then
		while frame_idx < #FD.frame_map and t >= FD.frame_map[frame_idx + 1] do
			frame_idx = frame_idx + 1
		end
		if frame_idx > #FD.frame_map then
			frame_idx = 1
			t = 0 -- loop
		end
	end
end

-- Draw duck sprite + oscilloscope waves
-- Call from on_draw()
-- x, y, w, h: destination rect
-- alpha: global opacity (0-255)
function M.draw(x, y, w, h, alpha)
	alpha = alpha or 255
	if not bin or not FD then
		return
	end

	-- Draw sprite
	local off = FD.frame_offsets[frame_idx] or 0
	local frame_w = FD.w
	local frame_h = FD.h
	if off + frame_w * frame_h * 4 <= #bin then
		local rgba = bin:sub(off + 1, off + frame_w * frame_h * 4)
		dm.draw.blit(x, y, w, h, rgba, alpha)
	end

	-- Draw oscilloscope waves from active notes
	local n_notes = 0
	for _ in pairs(notes) do
		n_notes = n_notes + 1
	end
	if n_notes == 0 then
		return
	end

	local wave_y = y + h + 4
	local wave_h = 16 + n_notes * 4
	local scope_w = w > 48 and 48 or w

	local i = 0
	for note, info in pairs(notes) do
		local freq = 440 * 2 ^ ((note - 69) / 12)
		local amp = (info.vel or 0.63) * wave_h * 0.4
		local phase = i * 1.3
		local color = (i % 2 == 0) and COL.turq or COL.violet

		-- Oscilloscope beam: sine wave tracing
		local px_prev, py_prev
		for px = 0, scope_w, 2 do
			local angle = t * freq * 0.15 + px * 0.25 + phase
			local vy = wave_y + math.sin(angle) * amp
			if px_prev then
				dm.draw.line(px_prev, py_prev, x + px, vy, color[1], color[2], color[3], 180)
			end
			px_prev = x + px
			py_prev = vy
		end
		wave_y = wave_y + 8
		i = i + 1
	end

	-- Beat flash indicator
	local beat_phase = (beat_t * bpm / 60) % 1
	if beat_phase < 0.05 then
		local bx = x + w / 2
		local by = y + h / 2
		dm.draw.circle(bx, by, 2 + beat_phase * 10, COL.turq[1], COL.turq[2], COL.turq[3], 60)
	end
end

-- Returns current frame info for MIDI player sync
function M.get_frame_info()
	local note_list = {}
	local total_notes = 0
	for n, info in pairs(notes) do
		table.insert(note_list, { note = n, vel = info.vel or 0.63, age = info.age or 0 })
		total_notes = total_notes + 1
	end
	return {
		frame = frame_idx,
		total_frames = FD and FD.total or 51,
		t = t,
		active_notes = note_list,
		n_notes = total_notes,
		bpm = bpm,
	}
end

return M
