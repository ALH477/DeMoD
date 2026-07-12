-- SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
--[[ ============================================================================
  patches/demod-drum-machine/pattern.lua — sequencer model + transport (pure).

  No dm.*, no audio: holds the grid, the per-step velocity, A–D banks, and the
  fixed-timestep transport clock. Unit-tested by selftest.lua.

  Grid: banks[b][voice][step] = { on=bool, vel=0..1 }. All edit ops act on the
  active bank. Transport advances a 0-based playhead `pos` on a fixed-step
  accumulator (acc += dt; while acc >= step_dur do advance end) so timing is
  frame-rate independent — same idiom as patches/demod-snake/main.lua.

  Serialization targets gamekit's K.save, which only persists TOP-LEVEL scalars,
  so the whole grid round-trips through a single compact STRING:
    per step  '.'=off, '1'..'3'=on at velocity level lo/med/hi
    per voice 16 chars, voices joined by '/', banks joined by '|'.

  © 2026 DeMoD LLC. Private.
============================================================================ ]]
local floor, max, min = math.floor, math.max, math.min

local P = {}
P.__index = P

-- three discrete velocity levels surfaced in the UI (lo / med / hi)
P.VEL = { 0.35, 0.7, 1.0 }

-- snap a continuous velocity to its nearest discrete UI level index (1..#VEL)
local function vel_level(vel)
	local idx, bestd = #P.VEL, 1e9
	for i, lv in ipairs(P.VEL) do
		local d = math.abs(lv - (vel or 1.0))
		if d < bestd then
			bestd, idx = d, i
		end
	end
	return idx
end

local function vel_to_char(on, vel)
	if not on then
		return "."
	end
	return tostring(vel_level(vel)) -- '1'..'3'
end

local function char_to_cell(c)
	local d = tonumber(c)
	if c == "." or c == "0" or c == "" or not d then
		return { on = false, vel = P.VEL[3] }
	end
	d = max(1, min(#P.VEL, floor(d)))
	return { on = true, vel = P.VEL[d] }
end

function P.new(nvoices, nsteps, nbanks)
	local self = setmetatable({}, P)
	self.nv = nvoices or 8
	self.ns = nsteps or 16
	self.nb = nbanks or 4
	self.bank = 1
	-- transport
	self.bpm = 120
	self.spb = 4 -- steps per beat (16 steps = one bar of 4/4)
	self.pos = 0 -- 0-based current step
	self.acc = 0
	self.playing = false
	self.banks = {}
	for b = 1, self.nb do
		self.banks[b] = {}
		for v = 1, self.nv do
			self.banks[b][v] = {}
			for s = 1, self.ns do
				self.banks[b][v][s] = { on = false, vel = P.VEL[3] }
			end
		end
	end
	return self
end

function P:grid()
	return self.banks[self.bank]
end

function P:cell(v, s)
	local g = self.banks[self.bank]
	return g[v] and g[v][s] or nil
end

function P:toggle(v, s)
	local c = self:cell(v, s)
	if not c then
		return
	end
	c.on = not c.on
	if c.on and (not c.vel or c.vel <= 0) then
		c.vel = P.VEL[3]
	end
end

function P:set(v, s, on, vel)
	local c = self:cell(v, s)
	if not c then
		return
	end
	c.on = on and true or false
	if vel then
		c.vel = max(0.0, min(1.0, vel))
	end
end

-- cycle the velocity of an ON cell through lo→med→hi→lo (no effect when off)
function P:cycle_vel(v, s)
	local c = self:cell(v, s)
	if not c or not c.on then
		return
	end
	-- find nearest current level, step to the next
	local idx = 3
	local bestd = 1e9
	for i, lv in ipairs(P.VEL) do
		local d = math.abs(lv - (c.vel or 1.0))
		if d < bestd then
			bestd, idx = d, i
		end
	end
	idx = (idx % #P.VEL) + 1
	c.vel = P.VEL[idx]
end

function P:clear() -- active bank only
	for v = 1, self.nv do
		for s = 1, self.ns do
			self.banks[self.bank][v][s] = { on = false, vel = P.VEL[3] }
		end
	end
end

function P:set_bank(b)
	if b >= 1 and b <= self.nb then
		self.bank = b
	end
end

function P:set_bpm(b)
	self.bpm = max(40, min(300, b))
end

-- seconds per step at the current tempo
function P:step_dur()
	return 60.0 / self.bpm / self.spb
end

-- advance the transport by dt. Returns a list of 0-based step indices that the
-- playhead entered during this tick (usually 0 or 1 entries; >1 only if dt is
-- larger than a step). Caller fires every ON voice at each returned step.
function P:advance(dt)
	if not self.playing then
		return {}
	end
	local fired = {}
	local sd = self:step_dur()
	self.acc = self.acc + dt
	-- guard against a runaway loop after a long stall
	local budget = self.ns * 2
	while self.acc >= sd and budget > 0 do
		self.acc = self.acc - sd
		self.pos = (self.pos + 1) % self.ns
		fired[#fired + 1] = self.pos
		budget = budget - 1
	end
	return fired
end

function P:start()
	self.playing = true
	self.acc = 0
	self.pos = self.ns - 1 -- so the first advance lands on step 0
end

function P:stop()
	self.playing = false
end

-- Advance exactly one step, ignoring dt — driven by an external MIDI clock's
-- 16th-note step callback instead of the dt accumulator. Returns { pos } or {}.
function P:step_once()
	if not self.playing then
		return {}
	end
	self.pos = (self.pos + 1) % self.ns
	return { self.pos }
end

-- the ON voices at a given 0-based step of the active bank, as a list of voice
-- indices with their velocity: { {v=, vel=}, ... }
function P:hits_at(step0)
	local out = {}
	local s = step0 + 1
	local g = self.banks[self.bank]
	for v = 1, self.nv do
		local c = g[v][s]
		if c and c.on then
			out[#out + 1] = { v = v, vel = c.vel or 1.0 }
		end
	end
	return out
end

-- ── persistence ──────────────────────────────────────────────────────────────
function P:serialize()
	local banks = {}
	for b = 1, self.nb do
		local voices = {}
		for v = 1, self.nv do
			local chars = {}
			for s = 1, self.ns do
				local c = self.banks[b][v][s]
				chars[s] = vel_to_char(c.on, c.vel)
			end
			voices[v] = table.concat(chars)
		end
		banks[b] = table.concat(voices, "/")
	end
	return table.concat(banks, "|")
end

-- rebuild grid contents from a serialized string (shape must match nv/ns/nb;
-- missing cells stay off). Returns self for chaining.
function P:deserialize(str)
	if type(str) ~= "string" or str == "" then
		return self
	end
	local b = 0
	for bankstr in (str .. "|"):gmatch("([^|]*)|") do
		b = b + 1
		if b > self.nb then
			break
		end
		local v = 0
		for vstr in (bankstr .. "/"):gmatch("([^/]*)/") do
			v = v + 1
			if v > self.nv then
				break
			end
			for s = 1, self.ns do
				local ch = vstr:sub(s, s)
				self.banks[b][v][s] = char_to_cell(ch)
			end
		end
	end
	return self
end

return P
