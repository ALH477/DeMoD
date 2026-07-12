-- SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
--[[ ============================================================================
  patches/demod-sampler/pads.lua — the 16-pad model (pure, dm-free).

  Each pad binds to a StreamDB sample id (+ a cached display name + gain). The
  whole bank serializes to one string for gamekit's K.save (which only persists
  top-level scalars):  per pad "i\tid\tname\tgain", pads joined by "\n".

  © 2026 DeMoD LLC. Private.
============================================================================ ]]
local P = {}
P.__index = P

function P.new(n)
	local self = setmetatable({}, P)
	self.n = n or 16
	self.pad = {}
	for i = 1, self.n do
		self.pad[i] = { id = nil, name = nil, gain = 1.0 }
	end
	return self
end

function P:get(i)
	return self.pad[i]
end

function P:assign(i, id, name)
	local p = self.pad[i]
	if not p then
		return
	end
	p.id = id
	p.name = name or id
end

function P:clear(i)
	if self.pad[i] then
		self.pad[i] = { id = nil, name = nil, gain = 1.0 }
	end
end

function P:set_gain(i, g)
	local p = self.pad[i]
	if p then
		p.gain = math.max(0.0, math.min(1.5, g))
	end
end

function P:bump_gain(i, d)
	local p = self.pad[i]
	if p then
		self:set_gain(i, (p.gain or 1.0) + d)
	end
end

function P:assigned_count()
	local c = 0
	for i = 1, self.n do
		if self.pad[i].id then
			c = c + 1
		end
	end
	return c
end

-- drop pads whose sample id no longer exists in the library (set `live[id]=true`)
function P:prune(live)
	for i = 1, self.n do
		local p = self.pad[i]
		if p.id and not live[p.id] then
			self:clear(i)
		end
	end
end

function P:serialize()
	local rows = {}
	for i = 1, self.n do
		local p = self.pad[i]
		if p.id then
			rows[#rows + 1] = table.concat({ i, p.id, p.name or "", string.format("%.3f", p.gain or 1.0) }, "\t")
		end
	end
	return table.concat(rows, "\n")
end

function P:deserialize(str)
	if type(str) ~= "string" or str == "" then
		return self
	end
	for line in str:gmatch("([^\n]+)") do
		local i, id, name, gain = line:match("^(%d+)\t([^\t]*)\t([^\t]*)\t([^\t]*)$")
		i = tonumber(i)
		if i and i >= 1 and i <= self.n and id and #id > 0 then
			self.pad[i] = { id = id, name = (name ~= "" and name or id), gain = tonumber(gain) or 1.0 }
		end
	end
	return self
end

return P
