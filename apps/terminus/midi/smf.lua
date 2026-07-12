-- SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
--[[ ============================================================================
  midi/smf.lua — shared Standard MIDI File import/export (pure, dm-free).

  Promoted from patches/demod-drum-machine so the sampler and any other patch can
  read/write .mid without copying a parser. No dm.*; binary I/O + Lua 5.4 bitops.

  Reader: parse an SMF (format 0/1), gather note-on events across all tracks, fold
  them onto a 16-step bar (4 steps / quarter) and map GM drum notes to voices via a
  `voices` adapter ({ gm_to_voice(note), count, list[].note }):

      ok, res = M.import(path, voices)
        res = { bpm = <tempo meta, default 120>,
                hits = { { v=voice, s=1..16, vel=0..1 }, ... } }

  Writer: emit a type-0 SMF (96 ticks/quarter, 24/step) from a pattern's active
  bank — one note_on/off per ON step, plus a tempo meta and end-of-track:

      ok, err = M.export(path, pattern, voices)

  © 2026 DeMoD LLC. Private.
============================================================================ ]]
local floor = math.floor
local M = {}

local DIV = 96 -- ticks per quarter note we write
local TICKS_PER_STEP_W = DIV // 4 -- 24
local NSTEPS = 16

-- ── byte helpers ─────────────────────────────────────────────────────────────
local function u16(s, p)
	return s:byte(p) * 256 + s:byte(p + 1)
end
local function u32(s, p)
	return ((s:byte(p) * 256 + s:byte(p + 1)) * 256 + s:byte(p + 2)) * 256 + s:byte(p + 3)
end

local function read_varlen(s, p)
	local v = 0
	repeat
		local b = s:byte(p)
		p = p + 1
		v = v * 128 + (b & 0x7F)
	until b < 0x80
	return v, p
end

-- data bytes for a channel-voice status (high nibble)
local function voice_len(status)
	local hi = status & 0xF0
	if hi == 0xC0 or hi == 0xD0 then
		return 1
	end
	return 2
end

-- ── import ───────────────────────────────────────────────────────────────────
function M.import(path, voices)
	local f = io.open(path, "rb")
	if not f then
		return false, "cannot open " .. tostring(path)
	end
	local data = f:read("*a")
	f:close()
	if not data or #data < 14 or data:sub(1, 4) ~= "MThd" then
		return false, "not a MIDI file"
	end

	local division = u16(data, 13)
	if division == 0 or (division & 0x8000) ~= 0 then
		division = DIV -- SMPTE/odd division: fall back to a sane PPQN
	end
	local tps = division / 4 -- ticks per 16th step
	local bpm = 120

	-- accumulate hits keyed by voice,step → max velocity seen
	local cell = {} -- cell[v][s] = vel

	local pos = 15 -- first chunk starts right after the 14-byte header
	while pos + 8 <= #data do
		local id = data:sub(pos, pos + 3)
		local len = u32(data, pos + 4)
		local body = pos + 8
		if id ~= "MTrk" then
			pos = body + len
		else
			local tend = body + len
			local tick = 0
			local running = 0
			local p = body
			while p < tend do
				local dt
				dt, p = read_varlen(data, p)
				tick = tick + dt
				local b = data:byte(p)
				local status
				if b >= 0x80 then
					status = b
					p = p + 1
					running = (b < 0xF0) and b or running
				else
					status = running -- running status: b is the first data byte
				end
				if status == 0xFF then -- meta
					local mtype = data:byte(p)
					p = p + 1
					local mlen
					mlen, p = read_varlen(data, p)
					if mtype == 0x51 and mlen == 3 then -- set tempo (us/qn)
						local usq = (data:byte(p) * 256 + data:byte(p + 1)) * 256 + data:byte(p + 2)
						if usq > 0 then
							bpm = floor(60000000 / usq + 0.5)
						end
					end
					p = p + mlen
				elseif status == 0xF0 or status == 0xF7 then -- sysex
					local slen
					slen, p = read_varlen(data, p)
					p = p + slen
				else -- channel voice
					local n = voice_len(status)
					local d1 = data:byte(p) or 0
					local d2 = (n == 2) and (data:byte(p + 1) or 0) or 0
					p = p + n
					local hi = status & 0xF0
					if hi == 0x90 and d2 > 0 then
						local v = voices.gm_to_voice(d1)
						if v then
							local s = floor(tick / tps + 0.5) % NSTEPS + 1
							cell[v] = cell[v] or {}
							local nv = d2 / 127
							if not cell[v][s] or nv > cell[v][s] then
								cell[v][s] = nv
							end
						end
					end
				end
			end
			pos = tend
		end
	end

	local hits = {}
	for v, steps in pairs(cell) do
		for s, vel in pairs(steps) do
			hits[#hits + 1] = { v = v, s = s, vel = vel }
		end
	end
	return true, { bpm = bpm, hits = hits }
end

-- ── export ───────────────────────────────────────────────────────────────────
local function vlq(n)
	local out = { n & 0x7F }
	n = n >> 7
	while n > 0 do
		table.insert(out, 1, (n & 0x7F) | 0x80)
		n = n >> 7
	end
	local s = {}
	for i = 1, #out do
		s[i] = string.char(out[i])
	end
	return table.concat(s)
end

local function be16(n)
	return string.char((n >> 8) & 0xFF, n & 0xFF)
end
local function be32(n)
	return string.char((n >> 24) & 0xFF, (n >> 16) & 0xFF, (n >> 8) & 0xFF, n & 0xFF)
end

function M.export(path, pattern, voices)
	-- collect absolute-tick events for the active bank
	local evs = {} -- { tick, bytes, ord }
	local function ev(tick, bytes, ord)
		evs[#evs + 1] = { tick = tick, bytes = bytes, ord = ord or 0 }
	end
	for s = 1, NSTEPS do
		local t = (s - 1) * TICKS_PER_STEP_W
		for v = 1, voices.count do
			local c = pattern:cell(v, s)
			if c and c.on then
				local note = voices.list[v].note
				local vel = floor((c.vel or 1.0) * 127 + 0.5)
				if vel < 1 then
					vel = 1
				end
				ev(t, string.char(0x99, note, vel), 1) -- note on, ch10 (0x99)
				ev(t + TICKS_PER_STEP_W // 2, string.char(0x89, note, 0), 0) -- note off
			end
		end
	end
	-- tempo meta at tick 0
	local usq = floor(60000000 / pattern.bpm + 0.5)
	local tempo = string.char(0xFF, 0x51, 0x03, (usq >> 16) & 0xFF, (usq >> 8) & 0xFF, usq & 0xFF)

	table.sort(evs, function(a, b)
		if a.tick ~= b.tick then
			return a.tick < b.tick
		end
		return a.ord < b.ord -- note_off before note_on at the same tick
	end)

	local track = { vlq(0) .. tempo }
	local last = 0
	for _, e in ipairs(evs) do
		track[#track + 1] = vlq(e.tick - last) .. e.bytes
		last = e.tick
	end
	track[#track + 1] = vlq((NSTEPS * TICKS_PER_STEP_W) - last) .. string.char(0xFF, 0x2F, 0x00)
	local tbytes = table.concat(track)

	local out = "MThd" .. be32(6) .. be16(0) .. be16(1) .. be16(DIV) .. "MTrk" .. be32(#tbytes) .. tbytes

	local f = io.open(path, "wb")
	if not f then
		return false, "cannot write " .. tostring(path)
	end
	f:write(out)
	f:close()
	return true
end

-- ── melodic note I/O (general piano-roll, any pitch, channel 1) ───────────────
-- Distinct from the drum import/export above (GM-folded, ch10): these carry full
-- pitch + per-note length for the SEQUENCER screen.
--
--   pat = { bpm = 120, steps = 16, ppq = 96?, notes = { {note,step,len,vel}, ... } }
--     note 0..127 · step 1-based · len in STEPS (>=1) · vel 0..1
function M.write_notes(path, pat)
	local div = pat.ppq or DIV
	local tps = div // 4
	local steps = math.max(1, pat.steps or NSTEPS)

	local evs = {}
	local function ev(tick, bytes, ord)
		evs[#evs + 1] = { tick = tick, bytes = bytes, ord = ord or 0 }
	end
	for _, nt in ipairs(pat.notes or {}) do
		local note = nt.note
		if note and note >= 0 and note <= 127 then
			local s = math.max(0, (nt.step or 1) - 1)
			local len = math.max(1, nt.len or 1)
			local vel = floor((nt.vel or 0.8) * 127 + 0.5)
			if vel < 1 then
				vel = 1
			end
			local t0 = s * tps
			ev(t0, string.char(0x90, note, vel), 1) -- note on, ch1
			ev(t0 + len * tps, string.char(0x80, note, 0), 0) -- note off (ord 0 = before on)
		end
	end

	local usq = floor(60000000 / (pat.bpm or 120) + 0.5)
	local tempo = string.char(0xFF, 0x51, 0x03, (usq >> 16) & 0xFF, (usq >> 8) & 0xFF, usq & 0xFF)

	table.sort(evs, function(a, b)
		if a.tick ~= b.tick then
			return a.tick < b.tick
		end
		return a.ord < b.ord
	end)

	local track = { vlq(0) .. tempo }
	local last = 0
	for _, e in ipairs(evs) do
		track[#track + 1] = vlq(e.tick - last) .. e.bytes
		last = e.tick
	end
	local total = steps * tps
	if total < last then
		total = last
	end
	track[#track + 1] = vlq(total - last) .. string.char(0xFF, 0x2F, 0x00)
	local tbytes = table.concat(track)

	local out = "MThd" .. be32(6) .. be16(0) .. be16(1) .. be16(div) .. "MTrk" .. be32(#tbytes) .. tbytes
	local f = io.open(path, "wb")
	if not f then
		return false, "cannot write " .. tostring(path)
	end
	f:write(out)
	f:close()
	return true
end

-- read any SMF back into the melodic pattern shape (all pitches, with lengths)
function M.read_notes(path)
	local f = io.open(path, "rb")
	if not f then
		return false, "cannot open " .. tostring(path)
	end
	local data = f:read("*a")
	f:close()
	if not data or #data < 14 or data:sub(1, 4) ~= "MThd" then
		return false, "not a MIDI file"
	end
	local division = u16(data, 13)
	if division == 0 or (division & 0x8000) ~= 0 then
		division = DIV
	end
	local tps = division / 4
	local bpm = 120

	local notes = {}
	local open = {} -- open[note] = { tick0, vel } for the most recent unmatched note-on
	local maxtick = 0
	local pos = 15
	while pos + 8 <= #data do
		local id = data:sub(pos, pos + 3)
		local len = u32(data, pos + 4)
		local body = pos + 8
		if id ~= "MTrk" then
			pos = body + len
		else
			local tend = body + len
			local tick, running, p = 0, 0, body
			while p < tend do
				local dt
				dt, p = read_varlen(data, p)
				tick = tick + dt
				local b = data:byte(p)
				local status
				if b >= 0x80 then
					status = b
					p = p + 1
					running = (b < 0xF0) and b or running
				else
					status = running
				end
				if status == 0xFF then
					local mtype = data:byte(p)
					p = p + 1
					local mlen
					mlen, p = read_varlen(data, p)
					if mtype == 0x51 and mlen == 3 then
						local usq = (data:byte(p) * 256 + data:byte(p + 1)) * 256 + data:byte(p + 2)
						if usq > 0 then
							bpm = floor(60000000 / usq + 0.5)
						end
					end
					p = p + mlen
				elseif status == 0xF0 or status == 0xF7 then
					local slen
					slen, p = read_varlen(data, p)
					p = p + slen
				else
					local n = voice_len(status)
					local d1 = data:byte(p) or 0
					local d2 = (n == 2) and (data:byte(p + 1) or 0) or 0
					p = p + n
					local hi = status & 0xF0
					if hi == 0x90 and d2 > 0 then -- note on
						open[d1] = { tick = tick, vel = d2 / 127 }
					elseif (hi == 0x80) or (hi == 0x90 and d2 == 0) then -- note off
						local o = open[d1]
						if o then
							open[d1] = nil
							local step = floor(o.tick / tps + 0.5) + 1
							local len2 = floor((tick - o.tick) / tps + 0.5)
							if len2 < 1 then
								len2 = 1
							end
							notes[#notes + 1] = { note = d1, step = step, len = len2, vel = o.vel }
							if step + len2 - 1 > maxtick then
								maxtick = step + len2 - 1
							end
						end
					end
				end
			end
			pos = tend
		end
	end
	return true, { bpm = bpm, steps = math.max(NSTEPS, maxtick), notes = notes }
end

return M
