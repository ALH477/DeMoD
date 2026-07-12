-- SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
--[[ ============================================================================
  patches/demod-jam/main.lua — DeMoD Jam: a collaborative-audio surface that
  speaks the CERTIFIED DCF-Audio wire (17-byte DeModFrame, codec_id registry).

  This Jam UX is PolyForm Shield (like the rest of TERMINUS). It depends on the
  LGPL-3.0 framework modules (dcf_audio.lua, dcf_superpack.lua, dcf_fec.lua) as
  discrete modules — no Shield code flows into them and none of their code is
  copied into Shield files. fx.lua (Shield) is the PM-param authority.

  Pick a codec (PCM-diag / Opus / Faust-PM), tune a CHANNEL (a numeric frequency
  or a shared passphrase — the handshakeless rendezvous), choose a PROFILE
  (LATENCY-first or QUALITY-first), START a jam, and watch real DCF-Audio packets
  stream while a TUNED peer reassembles them and a MISTUNED peer rejects them.

  The PROFILE only changes the *delivery* of the certified frames, never their
  bytes or their timing:
    LATENCY  : SuperPack adjacent frame-pairs (34->32 B, one datagram, lower
               per-pair latency) + a shallow 1-block (~20 ms) jitter buffer.
    QUALITY  : Reed-Solomon FEC over the block payload (lost/corrupt bytes are
               *recovered*, not dropped) + a deeper 4-block (~80 ms) buffer.
  TIMING IS SYNCED NO MATTER WHAT: a single monotonic block clock sets the
  certified 24-bit `timestamp_us` (block_index * 20000 us), identical across a
  packet's frames and identical in both profiles, so playout/record stays
  sample-accurate regardless of the latency/quality trade-off.

  Real mic/speaker I/O is the orchestrator's job; this is the control + certified-
  wire surface. `back` = dm.quit() returns to TERMINUS.

  © 2026 DeMoD LLC.
============================================================================ ]]

local HERE = (debug.getinfo(1, "S").source:gsub("^@", "")):match("(.*/)") or "./"
local DA = dofile(HERE .. "dcf_audio.lua")
local SP = dofile(HERE .. "dcf_superpack.lua")
local FEC = dofile(HERE .. "dcf_fec.lua")
local FX = dofile(HERE .. "fx.lua")

local WIRE_OK = DA.CERTIFIED and SP.CERTIFIED and FEC.CERTIFIED

local floor, sin, min, max = math.floor, math.sin, math.min, math.max

local COL = {
	bg = { 10, 10, 15 },
	white = { 232, 232, 240 },
	dim = { 106, 106, 134 },
	green = { 76, 255, 130 },
	cyan = { 80, 230, 220 },
	red = { 240, 90, 90 },
	amber = { 240, 190, 90 },
	sel = { 30, 34, 52 },
	tune = { 250, 210, 90 },
}
local FIELD = {
	{ 240, 90, 90 },
	{ 240, 160, 80 },
	{ 240, 220, 90 },
	{ 240, 220, 90 },
	{ 120, 230, 120 },
	{ 120, 230, 120 },
	{ 80, 220, 220 },
	{ 80, 220, 220 },
	{ 120, 160, 250 },
	{ 120, 160, 250 },
	{ 120, 160, 250 },
	{ 120, 160, 250 },
	{ 210, 120, 240 },
	{ 210, 120, 240 },
	{ 210, 120, 240 },
	{ 150, 150, 170 },
	{ 150, 150, 170 },
}

local MESH_STATE = os.getenv("DEMOD_MESH_STATE") or "/var/lib/demod/mesh.json"
local function read_mesh()
	local f = io.open(MESH_STATE, "r")
	if not f then
		return { peers = 0, linked = false }
	end
	local body = f:read("*a") or ""
	f:close()
	local pc = tonumber(body:match('"peerCount"%s*:%s*(%d+)')) or 0
	return { peers = pc, linked = body:match('"linked"%s*:%s*true') ~= nil or pc > 0 }
end

local CODECS = {
	{ name = "PCM-diag", id = DA.CODEC_PCM_DIAG, rate = 6000, block = 120 },
	{ name = "Opus", id = DA.CODEC_OPUS, rate = 48000, block = 960 },
	{ name = "Faust-PM", id = DA.CODEC_FAUST_PM, rate = 48000, block = 960 },
}
local PASS = { "(numeric)", "basement-jam", "146.520", "DeMoD" }

-- PROFILE: the latency/quality trade-off. Timing (ts24) is identical in both.
local PROFILES = {
	{ key = "latency", name = "LATENCY-first", buf_blocks = 1, note = "SuperPack pairs, ~20 ms buffer" },
	{ key = "quality", name = "QUALITY-first", buf_blocks = 4, note = "Reed-Solomon FEC, ~80 ms buffer" },
}
local FEC_NPARITY = 16 -- RS 2t=16 -> corrects 8 byte-errors per codeword

local ROW_FREQ = #CODECS + 1
local ROW_PASS = #CODECS + 2
local ROW_PROF = #CODECS + 3
local ROW_CONNECT = #CODECS + 4
local ROW_XPORT = #CODECS + 5
local NROWS = ROW_XPORT

local S = {
	focus = 1,
	codec = 1,
	profile = 1,
	running = false,
	tuning = false,
	show_help = false,
	channel = 1420,
	pass = 1,
	t = 0,
	acc = 0,
	block = 0,
	packets = 0,
	frames = 0,
	datagrams = 0,
	last_bytes = 0,
	last_ts = 0,
	last_frames = nil,
	last_super = nil,
	last_fec = nil,
	ended = false,
	mesh = read_mesh(),
	mesh_acc = 0,
	-- receive side (the handshakeless rendezvous, demonstrated live)
	monitor = nil,
	shadow = nil,
	monitor_ch = nil,
	recovered = 0,
	rejected = 0,
}

local function active_channel()
	if S.pass == 1 then
		return S.channel & 0xFFFF, ("CH %d"):format(S.channel & 0xFFFF)
	end
	local ch = DA.channel_from_passphrase(PASS[S.pass])
	return ch, ("%q -> CH %d"):format(PASS[S.pass], ch)
end

local function mistuned_of(ch)
	if ch == DA.BROADCAST then
		return 0x1000
	end
	return (ch ~ 0x5A5A) & 0xFFFF
end

-- (Re)build the receive monitor: a peer TUNED to `ch` plus a deliberately
-- MISTUNED shadow, so the certified accepts() rendezvous filter is shown live.
local function make_monitor(ch)
	S.monitor = DA.Reassembler.new(ch)
	S.shadow = DA.Reassembler.new(mistuned_of(ch))
	S.monitor_ch = ch
	S.recovered = 0
	S.rejected = 0
end

local function push_monitor(frame)
	local p = S.monitor:push(frame)
	if p then
		S.recovered = S.recovered + 1
	end
	S.shadow:push(frame)
	S.rejected = S.shadow.rejected
end

local function make_payload(cdef, n)
	if cdef.id == DA.CODEC_FAUST_PM then
		-- PM params come from fx.lua now and travel as the certified 8-byte block.
		return DA.pm_pack(FX.pm_block())
	elseif cdef.id == DA.CODEC_PCM_DIAG then
		local s = {}
		for i = 1, DA.PCM_DIAG_BLOCK do
			s[i] = 0.7 * sin((n * DA.PCM_DIAG_BLOCK + i) * 440.0 * 2 * math.pi / cdef.rate)
		end
		return DA.pcm_diag_encode(s)
	else
		-- Opus payload is synthesised for the wire view only (NOT byte-certified).
		local b, seed = {}, (n * 2654435761) & 0xFFFFFFFF
		for i = 1, 60 do
			seed = (seed * 1103515245 + 12345) & 0xFFFFFFFF
			b[i] = (seed >> 16) & 0xFF
		end
		return b
	end
end

local function reset_stream()
	S.packets, S.frames, S.datagrams, S.block, S.acc = 0, 0, 0, 0, 0
	S.last_super, S.last_fec, S.ended = nil, nil, false
	make_monitor((active_channel()))
end

-- LATENCY profile: SuperPack adjacent frame pairs (34->32 B, one datagram each),
-- then prove the round-trip is lossless by unpacking into the tuned monitor.
local function deliver_latency(frames)
	local dgrams, i = 0, 1
	while i <= #frames do
		if i + 1 <= #frames then
			local sp = SP.pack(frames[i], frames[i + 1])
			if sp then
				if i == 1 then
					S.last_super = sp
				end
				local a, b = SP.unpack(sp)
				push_monitor(a)
				push_monitor(b)
				dgrams = dgrams + 1
				i = i + 2
			else
				push_monitor(frames[i])
				dgrams = dgrams + 1
				i = i + 1
			end
		else
			push_monitor(frames[i])
			dgrams = dgrams + 1
			i = i + 1
		end
	end
	S.datagrams = S.datagrams + dgrams
	S.last_fec = nil
end

-- QUALITY profile: Reed-Solomon FEC over the block payload — inject one byte
-- error and show it is RECOVERED (not dropped), the quality/resilience win.
local function deliver_quality(payload, frames)
	local n = #payload
	if n > 0 then
		local msg = string.char(table.unpack(payload, 1, n))
		local blob = FEC.encode_message(msg, FEC_NPARITY)
		local bb = { blob:byte(1, #blob) }
		local hit = #bb // 2 -- a single-byte burst, well inside RS t=8
		bb[hit] = bb[hit] ~ 0x5A
		local corrupted = string.char(table.unpack(bb))
		local ok, rec = pcall(FEC.decode_message, corrupted)
		S.last_fec = {
			msglen = n,
			parity = #blob - n,
			recovered = ok and rec == msg,
		}
	else
		S.last_fec = { msglen = 0, parity = 0, recovered = true }
	end
	S.last_super = nil
	for _, f in ipairs(frames) do
		push_monitor(f)
	end
end

local function jam_tick()
	local cdef = CODECS[S.codec]
	local ch = active_channel()
	if ch ~= S.monitor_ch then
		make_monitor(ch) -- re-tune the monitor if the rendezvous channel changed
	end
	-- SYNCED CLOCK: one block clock drives ts24 in BOTH profiles, identical across
	-- a packet's frames. This is the DCF_AUDIO_SPEC capture timestamp.
	local ts = (S.block * 20000) & 0xFFFFFF
	local pid = S.block & DA.MAX_PACKETID
	local payload = make_payload(cdef, S.block)
	local frames = DA.packetize(cdef.id, payload, pid, ts, 1, ch, 0)

	S.last_frames = frames
	S.last_bytes = #payload
	S.last_ts = ts
	S.packets = S.packets + 1
	S.frames = S.frames + #frames

	if PROFILES[S.profile].key == "latency" then
		deliver_latency(frames)
	else
		deliver_quality(payload, frames)
	end

	S.block = S.block + 1
end

-- Talkspurt end: one final descriptor with FLAG_END_TALKSPURT (len 0), same clock.
local function send_end_talkspurt()
	local ch = active_channel()
	local ts = (S.block * 20000) & 0xFFFFFF
	local frames = DA.packetize(CODECS[S.codec].id, {}, S.block & DA.MAX_PACKETID, ts, 1, ch, DA.FLAG_END_TALKSPURT)
	S.last_frames = frames
	S.last_super, S.last_fec = nil, nil
	S.last_ts = ts
	for _, f in ipairs(frames) do
		push_monitor(f)
	end
	S.ended = true
end

local function move(d)
	S.focus = ((S.focus - 1 + d) % NROWS) + 1
end
local function activate()
	if S.focus <= #CODECS then
		S.codec = S.focus
		if S.running then
			reset_stream()
		end
	elseif S.focus == ROW_FREQ then
		S.tuning = not S.tuning
	elseif S.focus == ROW_PASS then
		S.pass = (S.pass % #PASS) + 1
		if S.running then
			reset_stream()
		end
	elseif S.focus == ROW_PROF then
		S.profile = (S.profile % #PROFILES) + 1
		if S.running then
			reset_stream()
		end
	elseif S.focus == ROW_CONNECT then
		S.show_help = true
	elseif S.focus == ROW_XPORT then
		if S.running then
			send_end_talkspurt()
			S.running = false
		else
			S.running = true
			reset_stream()
		end
	end
end

function on_nav(action)
	if S.show_help then
		-- the CONNECT/HOST overlay swallows input; any key closes it
		S.show_help = false
		if dm.redraw then
			dm.redraw()
		end
		return
	end
	if action == "back" or action == "cancel" then
		if dm.quit then
			dm.quit()
		end
	elseif action == "up" or action == "prev" or action == "left" then
		if S.tuning and S.focus == ROW_FREQ then
			S.channel = (S.channel - 1) & 0xFFFF
		else
			move(-1)
		end
	elseif action == "down" or action == "next" or action == "right" then
		if S.tuning and S.focus == ROW_FREQ then
			S.channel = (S.channel + 1) & 0xFFFF
		else
			move(1)
		end
	elseif action == "activate" then
		activate()
	end
	if dm.redraw then
		dm.redraw()
	end
end

function on_input(evt, btn, val)
	if S.show_help then
		-- close the overlay on any discrete press or encoder push
		if evt == "DOWN" or evt == "ENC_CW" or evt == "ENC_CCW" or evt == "ENC_ACCEL_CW" or evt == "ENC_ACCEL_CCW" then
			S.show_help = false
		end
		if dm.redraw then
			dm.redraw()
		end
		return
	end
	if evt == "ENC_CW" or evt == "ENC_ACCEL_CW" then
		if S.tuning and S.focus == ROW_FREQ then
			S.channel = (S.channel + 1) & 0xFFFF
		else
			move(1)
		end
	elseif evt == "ENC_CCW" or evt == "ENC_ACCEL_CCW" then
		if S.tuning and S.focus == ROW_FREQ then
			S.channel = (S.channel - 1) & 0xFFFF
		else
			move(-1)
		end
	elseif evt == "DOWN" then
		if btn == "NAV_BACK" then
			if dm.quit then
				dm.quit()
			end
		elseif btn == "NAV_UP" then
			if S.tuning and S.focus == ROW_FREQ then
				S.channel = (S.channel - 1) & 0xFFFF
			else
				move(-1)
			end
		elseif btn == "NAV_DOWN" then
			if S.tuning and S.focus == ROW_FREQ then
				S.channel = (S.channel + 1) & 0xFFFF
			else
				move(1)
			end
		elseif btn == "NAV_SELECT" or btn == "ENC_PUSH" then
			activate()
		end
	end
	if dm.redraw then
		dm.redraw()
	end
end

function on_update(dt)
	S.t = S.t + dt
	if S.running then
		S.acc = S.acc + dt
		local g = 0
		while S.acc >= 0.020 and g < 8 do
			S.acc = S.acc - 0.020
			jam_tick()
			g = g + 1
		end
	end
	S.mesh_acc = S.mesh_acc + dt
	if S.mesh_acc > 1.0 then
		S.mesh = read_mesh()
		S.mesh_acc = 0
	end
	if dm.redraw then
		dm.redraw()
	end
end

local function txt(x, y, s, c, a)
	dm.draw.text(floor(x), floor(y), s, c[1], c[2], c[3], a or 230)
end
local function rect(x, y, w, h, c, a)
	dm.draw.rect(floor(x), floor(y), floor(w), floor(h), c[1], c[2], c[3], a or 255)
end

-- CONNECT / HOST overlay: the rendezvous params a real DCF endpoint must match,
-- plus the exact join + record commands. The patch is a local preview; multiplayer
-- and recording happen on a HydraMesh endpoint (full guide: HOSTING.md).
local function draw_connect(W, H)
	rect(0, 0, W, H, COL.bg)
	rect(10, 10, W - 20, H - 20, COL.sel, 235)
	local ch, _ = active_channel()
	local cdef = CODECS[S.codec]
	local passlabel = (S.pass == 1) and ("(numeric freq %d)"):format(ch) or ("%q"):format(PASS[S.pass])
	local x, y = 24, 22
	local function line(s, c, a)
		txt(x, y, s, c or COL.white, a)
		y = y + 15
	end
	line("CONNECT & HOST", COL.cyan)
	line("This patch is a LOCAL control + certified-wire preview — it does", COL.dim, 200)
	line("NOT transmit. Multiplayer & recording run on a real DCF endpoint", COL.dim, 200)
	line("that matches the rendezvous below.  Full guide: HOSTING.md", COL.dim, 200)
	y = y + 6
	line("RENDEZVOUS", COL.amber)
	line(("  channel    : %d   (0x%04X)"):format(ch, ch))
	line(("  passphrase : %s"):format(passlabel))
	line(("  codec      : id %d   %s"):format(cdef.id, cdef.name))
	line(("  profile    : %s"):format(PROFILES[S.profile].name))
	y = y + 6
	line("JOIN FROM A HYDRAMESH ENDPOINT", COL.green)
	line("  client : set_channel({passphrase=...}) or {freq=N}; same codec", COL.white, 215)
	line(("  node   : dcfnode send-audio --peer host:7777 --channel %d --codec %d"):format(ch, cdef.id), COL.white, 215)
	y = y + 6
	line("RECORD", COL.green)
	line("  client : start/stop -> master.mka + mix.flac  (needs ffmpeg)", COL.white, 215)
	line("  docker : dcf-radio --bind :7100 --http :8000 --dvr 6h  (HLS+DVR)", COL.white, 215)
	txt(x, H - 24, "[ press any key / back to close ]", COL.dim, 180)
end

function on_draw()
	local W, H = dm.width(), dm.height()
	if S.show_help then
		draw_connect(W, H)
		return
	end
	rect(0, 0, W, H, COL.bg)
	local off = (S.t * 14) % 4
	for y = 0, H, 4 do
		dm.draw.line(0, floor(y + off), W, floor(y + off), 18, 18, 30, 30)
	end

	txt(16, 12, "DEMOD JAM", COL.white)
	local lamp = WIRE_OK and COL.cyan or COL.red
	rect(W - 150, 12, 10, 10, lamp, WIRE_OK and (140 + floor(80 * (0.5 + 0.5 * sin(S.t * 4)))) or 200)
	txt(W - 134, 12, WIRE_OK and "WIRE CERTIFIED" or "WIRE FAULT", lamp)

	-- honest transport state: this patch never transmits on its own (see HOSTING.md).
	local m = S.mesh
	local status, mc
	if m.linked then
		status, mc = ("MESH linked  peers %d"):format(m.peers), COL.green
	elseif S.running then
		status, mc = "PREVIEW (local wire — not transmitting)", COL.amber
	else
		status, mc = "MESH offline", COL.dim
	end
	rect(16, 30, 8, 8, mc)
	local _, chlabel = active_channel()
	txt(28, 29, (status .. "   RENDEZVOUS %s"):format(chlabel), mc, 215)

	local y0 = 48
	for i, c in ipairs(CODECS) do
		local y = y0 + (i - 1) * 18
		if S.focus == i then
			rect(12, y - 2, W - 24, 16, COL.sel)
		end
		txt(
			20,
			y,
			((S.codec == i) and "(*)" or "( )") .. (" id %d  %s"):format(c.id, c.name),
			(S.codec == i) and COL.cyan or COL.dim
		)
	end
	local fy = y0 + #CODECS * 18 + 2
	if S.focus == ROW_FREQ then
		rect(12, fy - 2, W - 24, 16, S.tuning and COL.tune or COL.sel)
	end
	txt(
		20,
		fy,
		("FREQUENCY  CH %d  %s"):format(S.channel & 0xFFFF, S.tuning and "[tuning]" or ""),
		S.tuning and COL.tune or COL.white
	)
	local py = fy + 18
	if S.focus == ROW_PASS then
		rect(12, py - 2, W - 24, 16, COL.sel)
	end
	txt(20, py, "PASSPHRASE  " .. PASS[S.pass], COL.white)

	local prof = PROFILES[S.profile]
	local oy = py + 18
	if S.focus == ROW_PROF then
		rect(12, oy - 2, W - 24, 16, COL.sel)
	end
	txt(20, oy, ("PROFILE  %s"):format(prof.name), COL.cyan)
	txt(20 + 230, oy, prof.note, COL.dim, 180)

	local cy = oy + 18
	if S.focus == ROW_CONNECT then
		rect(12, cy - 2, W - 24, 16, COL.sel)
	end
	txt(20, cy, "CONNECT / HOST...", COL.white)
	txt(20 + 230, cy, "rendezvous + host/record guide", COL.dim, 180)

	local ty = cy + 18
	if S.focus == ROW_XPORT then
		rect(12, ty - 2, W - 24, 16, COL.sel)
	end
	txt(20, ty, S.running and "[#] STOP JAM" or "> START JAM", S.running and COL.green or COL.amber)

	-- synced-clock line: ts24 is identical in both profiles
	local sy = ty + 20
	txt(
		20,
		sy,
		("SYNC  ts=0x%06X  block %d  buffer %d ms  (capture-locked, profile-invariant)"):format(
			S.last_ts,
			S.block,
			prof.buf_blocks * 20
		),
		COL.green,
		200
	)

	local st = sy + 16
	txt(
		20,
		st,
		("packets %d  frames %d  block %d B"):format(S.packets, S.frames, S.last_bytes),
		COL.white,
		200
	)

	-- profile-specific delivery line
	local dl = st + 16
	if prof.key == "latency" and S.last_super then
		txt(20, dl, ("SuperPack  %d frames -> %d datagrams  (34->32 B/pair)"):format(S.frames, S.datagrams), COL.amber, 210)
	elseif prof.key == "quality" and S.last_fec then
		local f = S.last_fec
		txt(
			20,
			dl,
			("FEC  RS(+%d parity) over %d B  -> 1-byte err %s"):format(
				f.parity,
				f.msglen,
				f.recovered and "RECOVERED" or "LOST"
			),
			f.recovered and COL.green or COL.red,
			210
		)
	else
		txt(20, dl, "press START to stream", COL.dim, 160)
	end

	-- receive side: the handshakeless rendezvous, demonstrated live
	local ry = dl + 16
	local ch = active_channel()
	local rxlabel
	if ch == DA.BROADCAST then
		rxlabel = ("RX  TUNED CH %d: %d pkts recovered   (broadcast — all peers hear)"):format(ch, S.recovered)
	else
		rxlabel = ("RX  TUNED CH %d: %d pkts   MISTUNED: %d frames rejected (rendezvous)"):format(
			ch,
			S.recovered,
			S.rejected
		)
	end
	txt(20, ry, rxlabel, S.recovered > 0 and COL.cyan or COL.dim, 200)

	local gy = ry + 18
	local endlbl = S.ended and "  [END_TALKSPURT]" or ""
	txt(20, gy, "DeModFrame (descriptor) - dst = rendezvous channel" .. endlbl, COL.dim, 170)
	local frame = S.last_frames and S.last_frames[1]
	if frame then
		local m0, by = 16, gy + 15
		local cw = max(14, min(22, floor((W - 2 * m0) / 17)))
		for i = 1, 17 do
			local fc = FIELD[i]
			rect(m0 + (i - 1) * cw, by, cw - 2, 18, fc, 60)
			dm.draw.text(
				floor(m0 + (i - 1) * cw + 2),
				floor(by + 5),
				("%02X"):format(frame[i]),
				fc[1],
				fc[2],
				fc[3],
				240
			)
		end
	else
		txt(16, gy + 15, "press START to stream", COL.dim, 160)
	end

	local hint = "[ up/down move/tune  select choose/toggle  back exit ]"
	txt(W / 2 - #hint * 4, H - 14, hint, COL.dim, 170)
end

io.stderr:write(
	"[patch] demod-jam up; wire "
		.. (WIRE_OK and "CERTIFIED" or "FAULT")
		.. " (audio="
		.. tostring(DA.CERTIFIED)
		.. " superpack="
		.. tostring(SP.CERTIFIED)
		.. " fec="
		.. tostring(FEC.CERTIFIED)
		.. ")\n"
)
