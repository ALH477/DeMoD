-- SPDX-License-Identifier: MPL-2.0
--[[
  remote_client.lua — a thin remote UI that drives an engine over dm.dcf and
  shows what's happening: a pleasant "Connected" notification when the link comes
  up, and a LOUD failure toast when the engine rejects a control op.

  It is the native/browser remote client's UX in miniature — the same dm.dcf
  status()/poll_event() the DSP Studio's remote backend uses. Point it at a
  demod-remote-bridge (in front of an engine, or the stub):

    DEMOD_DCF_HOST=127.0.0.1 DEMOD_DCF_PORT=47000 ./demod-ui examples/remote_client.lua

  Env: DEMOD_RC_OP='<json>' sends one control op after connecting (to see the
  reply toast). DEMOD_RC_TEST=1 runs a headless assertion (connected [+ op_reply
  matching DEMOD_RC_EXPECT=ok|fail]) and exits — used by the bridge test harnesses.
  Copyright (c) 2026 DeMoD LLC. MPL-2.0; see LICENSE.
]]

local HOST    = os.getenv("DEMOD_DCF_HOST") or "127.0.0.1"
local PORT    = tonumber(os.getenv("DEMOD_DCF_PORT") or "47000")
local SEND_OP = os.getenv("DEMOD_RC_OP")            -- optional op sent after connect
local TEST    = os.getenv("DEMOD_RC_TEST") == "1"   -- headless self-test
local EXPECT  = os.getenv("DEMOD_RC_EXPECT") or "ok" -- "ok" | "fail"

local COL = {
    ok    = { 0x4C, 0xFF, 0x82 }, err   = { 0xFF, 0x4C, 0x6A },
    warn  = { 0xFF, 0xD9, 0x4C }, info  = { 0x00, 0xF5, 0xD4 },
    text  = { 0xE8, 0xE8, 0xF0 },
}

local toasts = {} -- { text, col, ttl }
local function toast(text, col, ttl)
    toasts[#toasts + 1] = { text = text, col = col, ttl = ttl or 4.0 }
    print("[toast] " .. text)
end

if not (dm and dm.dcf) then
    print("FAIL: dm.dcf absent (build with DCF=1)")
    os.exit(1)
end

local opened = dm.dcf.open(HOST, PORT)
if not opened then
    toast("Open failed: " .. HOST .. ":" .. PORT, COL.err, 6)
    if TEST then print("FAIL: dm.dcf.open failed"); os.exit(1) end
end

local frames, last_ping = 0, -999
local sent, seen_connected, seen_reply = false, false, nil

function on_update(dt)
    dt = dt or (1 / 60)
    frames = frames + 1

    if opened and (frames - last_ping) > 20 then
        last_ping = frames
        dm.dcf.ping()      -- drive the link; the first PONG raises "connected"
    end
    if opened then dm.dcf.poll() end   -- drain telemetry (+ any op-reply frames)

    -- Drain connection / op-reply events into toasts.
    if opened then
        while true do
            local ev = dm.dcf.poll_event()
            if not ev then break end
            if ev.kind == "connected" then
                seen_connected = true
                toast("Connected to " .. HOST .. ":" .. PORT, COL.ok, 4)
            elseif ev.kind == "disconnected" then
                toast("Engine disconnected", COL.warn, 5)
            elseif ev.kind == "op_reply" then
                seen_reply = ev.ok
                if ev.ok then
                    toast("Command applied", COL.ok, 2.5)
                else
                    toast("REJECTED: " .. ev.reason, COL.err, 6) -- the loud fail
                end
            end
        end
    end

    if opened and seen_connected and SEND_OP and not sent then
        sent = true
        dm.dcf.send(SEND_OP)
    end

    for i = #toasts, 1, -1 do
        toasts[i].ttl = toasts[i].ttl - dt
        if toasts[i].ttl <= 0 then table.remove(toasts, i) end
    end

    if TEST then
        local done = seen_connected and (SEND_OP == nil or seen_reply ~= nil)
        if done then
            local ok = seen_connected
            if SEND_OP then ok = ok and (seen_reply == (EXPECT == "ok")) end
            if ok then
                print("PASS: connected" ..
                    (SEND_OP and (", op_reply ok=" .. tostring(seen_reply)) or ""))
                dm.dcf.close(); os.exit(0)
            else
                print("FAIL: connected=" .. tostring(seen_connected) ..
                    " reply_ok=" .. tostring(seen_reply) .. " expect=" .. EXPECT)
                dm.dcf.close(); os.exit(1)
            end
        end
        if frames > 600 then
            print("FAIL: timed out (connected=" .. tostring(seen_connected) .. ")")
            os.exit(1)
        end
    end

    dm.redraw()
end

function on_draw()
    local W, H = dm.width(), dm.height()
    dm.draw.rect(0, 0, W, H, 0x0A, 0x0A, 0x0F, 255)
    dm.draw.gradient_v(0, 0, W, 3, 0x00, 0xF5, 0xD4, 0x8B, 0x5C, 0xF6)

    dm.draw.text(16, 16, "DeMoD REMOTE CLIENT", 0x00, 0xF5, 0xD4, 255)
    local st = dm.dcf.status()
    local sc = (st == "connected") and COL.ok or ((st == "connecting") and COL.warn or COL.err)
    dm.draw.text(16, 36, "engine " .. HOST .. ":" .. PORT .. "  [" .. st .. "]",
        sc[1], sc[2], sc[3], 230)

    -- Toast stack, newest at the bottom, fading out in its final moments.
    local pad, bh, gap = 12, 30, 8
    local y = H - 16 - bh
    for i = #toasts, 1, -1 do
        local t = toasts[i]
        local a = t.ttl < 0.6 and (t.ttl / 0.6) or 1.0
        local aa = math.floor(220 * a)
        local bw = dm.draw.text_width(t.text) + 2 * pad + 8
        local x = W - 16 - bw
        dm.draw.rect(x, y, bw, bh, 0x12, 0x12, 0x1E, math.floor(235 * a))
        dm.draw.rect(x, y, 4, bh, t.col[1], t.col[2], t.col[3], aa)
        dm.draw.text(x + pad + 8, y + 7, t.text, t.col[1], t.col[2], t.col[3], aa)
        y = y - (bh + gap)
        if y < 56 then break end
    end
end
