-- SPDX-License-Identifier: MPL-2.0
-- theme.lua — the shell's generic theme-resolve. Apps supply a palettes table
-- (e.g. {night=..., day=...}); resolve(setting, palettes) returns one palette.
-- "auto" picks night/day by time of day; any other key selects directly.
return function(setting, palettes)
  local t = setting
  if t == "auto" then
    local h = tonumber(os.date("%H")) or 12
    t = (h < 7 or h >= 19) and "night" or "day"
  end
  return palettes[t] or palettes.night or select(2, next(palettes))
end
