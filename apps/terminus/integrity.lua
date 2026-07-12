-- SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
-- Integrity check stub (demo version)
-- Always returns ok=true for demo builds

return {
	check = function()
		return {
			ok = true,
			signed = false,
			rev = "demo",
			problems = {},
		}
	end,
}
