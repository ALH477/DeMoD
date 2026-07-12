-- SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
--[[ ============================================================================
  dsp/bindings.lua — re-export shim.

  The param <-> interface-control registry moved up to the shared, top-level
  control_surface.lua so BOTH shells (home.lua and dsp/dsp_studio.lua) drive the same
  bidirectional param<->MIDI bridge. This shim keeps `ctx.bindings = dofile(".../bindings.lua")`
  and every `ctx.bindings.*` call in the BINDINGS / PARAMS screens working unchanged —
  control_surface.lua is a strict superset of the old API.

  © 2026 DeMoD LLC. Private.
============================================================================ ]]

local HERE = (debug.getinfo(1, "S").source:gsub("^@", "")):match("(.*/)") or "./"
return dofile(HERE .. "../control_surface.lua")
