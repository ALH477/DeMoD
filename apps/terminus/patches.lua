-- SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
-- Patch manager stub (demo version)
-- Returns empty patch list for demo builds

local PM = {
	list = {},
	errors = {},
	entitled = {},
}

function PM.load(dirs)
	-- No-op in demo version
end

function PM.load_order(path)
	-- No-op in demo version
end

function PM.load_owner(path)
	-- No-op in demo version
end

function PM.is_paid(patch)
	return false
end

function PM.is_entitled(patch)
	return true
end

function PM.counts()
	return { total = 0, app = 0, fx = 0, paid = 0 }
end

return PM
