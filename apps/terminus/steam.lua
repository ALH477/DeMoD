-- SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
-- Steam integration stub (demo version)
-- Returns no-op functions for all Steam API calls

return {
	is_edition = function() return false end,
	init = function() end,
	run_callbacks = function() end,
	dlc_owned = function() return false end,
	overlay_url = function() end,
	overlay_workshop = function() end,
}
