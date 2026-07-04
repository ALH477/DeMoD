---@meta
-- SPDX-License-Identifier: MPL-2.0
-- Type stubs for the C-injected `dm` API, so lua-language-server gives completion
-- and diagnostics when editing shells/examples. Best-effort and hand-maintained
-- (covers the surfaces apps use most); the authority is src/lua/lua_bindings.c +
-- SKILL.md. Loaded via .luarc.json (workspace.library). NOT executed.

------------------------------------------------------------------- drawing ----
-- Valid only inside on_draw(). Colors are r,g,b,a integers 0-255 (a optional).

---@class dm.draw
local draw = {}
---@param x integer @param y integer @param w integer @param h integer
---@param r integer @param g integer @param b integer @param a? integer
function draw.rect(x, y, w, h, r, g, b, a) end
---@param cx integer @param cy integer @param rad integer
---@param r integer @param g integer @param b integer @param a? integer
function draw.circle(cx, cy, rad, r, g, b, a) end
---@param x0 integer @param y0 integer @param x1 integer @param y1 integer
---@param r integer @param g integer @param b integer @param a? integer
function draw.line(x0, y0, x1, y1, r, g, b, a) end
---@param x0 integer @param y0 integer @param x1 integer @param y1 integer @param thick integer
---@param r integer @param g integer @param b integer @param a? integer
function draw.thick_line(x0, y0, x1, y1, thick, r, g, b, a) end
---@param x integer @param y integer @param s string
---@param r integer @param g integer @param b integer @param a? integer @param scale? integer
function draw.text(x, y, s, r, g, b, a, scale) end
---@param s string @param scale? integer
---@return integer pixels
function draw.text_width(s, scale) end
---@param x integer @param y integer @param w integer @param h integer
---@param r1 integer @param g1 integer @param b1 integer @param r2 integer @param g2 integer @param b2 integer
function draw.gradient_v(x, y, w, h, r1, g1, b1, r2, g2, b2) end
function draw.triangle(...) end
function draw.arrow(...) end
function draw.bezier(...) end
---@param x integer @param y integer @param w integer @param h integer @param rgba string @param alpha? integer
function draw.blit(x, y, w, h, rgba, alpha) end
function draw.sierpinski(...) end
function draw.sierpinski_glow(...) end

------------------------------------------------------------------- widgets ----
---@class dm.Widget
local Widget = {}
---@param child dm.Widget
function Widget:add_child(child) end
---@param x integer @param y integer @param w integer @param h integer
function Widget:set_bounds(x, y, w, h) end
---@param fn fun()
function Widget:on_click(fn) end
---@param fn fun(value:any)
function Widget:on_change(fn) end
---@return any
function Widget:get_value() end
---@param v any
function Widget:set_value(v) end
function Widget:set_bg(r, g, b, a) end
function Widget:set_fg(r, g, b, a) end
function Widget:show() end
function Widget:hide() end
function Widget:enable() end
function Widget:disable() end
---@param kind "vbox"|"hbox"|"grid" @param spacing? integer @param padding? integer @param cols? integer
function Widget:set_layout(kind, spacing, padding, cols) end
---@param label string
function Widget:add_item(label) end
function Widget:set_level(ch, lvl) end
function Widget:vu_update(dt) end
function Widget:push_sample(v) end
function Widget:set_format(fmt) end
---@return number x, number y
function Widget:get_xy() end
function Widget:set_xy(x, y) end

------------------------------------------------------------------- dm.dcf -----
---@class dm.dcf
local dcf = {}
---@param host string @param port integer @return boolean
function dcf.open(host, port) end
---@return number|nil rtt_ms
function dcf.ping() end
---@param op_json string @return boolean
function dcf.send(op_json) end
---@return table|nil meters
function dcf.poll() end
---@return table|nil event  # {kind, ok?, status?, reason?}
function dcf.poll_event() end
---@return "disconnected"|"connecting"|"connected"
function dcf.status() end
function dcf.close() end

--------------------------------------------------------------------- dm -------
---@class dm
---@field draw dm.draw
---@field dcf dm.dcf
---@field color table<string, integer[]>
dm = {}

---@return integer
function dm.width() end
---@return integer
function dm.height() end
function dm.redraw() end
---@param action "prev"|"next"|"activate"|"back"|"tab"|"tab_prev"|"wet"
function dm.nav(action) end
---@param cmd string @return boolean
function dm.exec(cmd) end
function dm.quit() end
---@param id string @return dm.Widget
function dm.find(id) end
---@return dm.Widget
function dm.root() end
---@return integer
function dm.mouse_x() end
---@return integer
function dm.mouse_y() end
---@param s string @return integer
function dm.utf8_len(s) end

-- widget constructors
---@param id string @return dm.Widget
function dm.panel(id) end
---@param id string @param text? string @return dm.Widget
function dm.label(id, text) end
---@param id string @param label? string @return dm.Widget
function dm.button(id, label) end
---@param id string @return dm.Widget
function dm.slider(id) end
---@param id string @return dm.Widget
function dm.toggle(id) end
---@param id string @param placeholder? string @return dm.Widget
function dm.text_input(id, placeholder) end
---@param id string @return dm.Widget
function dm.progress(id) end
---@param id string @param label string @param min number @param max number @param val number @return dm.Widget
function dm.knob(id, label, min, max, val) end
---@param id string @param channels integer @return dm.Widget
function dm.vu_meter(id, channels) end
---@param id string @param num_samples integer @return dm.Widget
function dm.waveform(id, num_samples) end
---@param id string @param placeholder? string @return dm.Widget
function dm.dropdown(id, placeholder) end
---@param id string @return dm.Widget
function dm.xy_pad(id) end
---@param id string @param content_w integer @param content_h integer @return dm.Widget
function dm.scroll_panel(id, content_w, content_h) end

-- engine control (local socket; present per build)
function dm.ctl_set_param(slot, idx, value) end
function dm.ctl_bypass(slot, on) end
function dm.ctl_bpm(bpm) end
function dm.ctl_gain(gain) end
---@param json_line string @return boolean
function dm.ctl(json_line) end

return dm
