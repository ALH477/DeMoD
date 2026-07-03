-- SPDX-License-Identifier: LGPL-3.0-only
--[[
  dcf_loopback.lua — headless proof for the dm.dcf UDP remote transport.

  Drives dm.dcf against a demod-remote-bridge + stub_engine over localhost UDP:
    1. open the peer,
    2. assert ping() returns an rtt number,
    3. send a control op (the stub logs it to its control socket),
    4. poll() until a telemetry meters table arrives and assert the known values.
  Prints PASS/FAIL and exits nonzero on failure. Driven from on_update across
  frames because the framework runs an event loop.
  Copyright (C) 2025-2026 DeMoD LLC. LGPL-3.0-only; see LICENSE.
]]

local PORT = tonumber(os.getenv("DEMOD_DCF_PORT") or "47000")

local function fail(msg)
    print("FAIL: " .. msg)
    if dm and dm.dcf then dm.dcf.close() end
    os.exit(1)
end

local function approx(a, b, tol)
    return a ~= nil and math.abs(a - b) <= tol
end

if not (dm and dm.dcf) then
    fail("dm.dcf is absent (build with DCF=1)")
end

if not dm.dcf.open("127.0.0.1", PORT) then
    fail("dm.dcf.open failed")
end
print("opened 127.0.0.1:" .. PORT)

local phase = "ping"
local frames = 0
local sent = false

function on_update(dt)
    frames = frames + 1
    if frames > 600 then
        fail("timed out after " .. frames .. " frames (phase=" .. phase .. ")")
    end

    if phase == "ping" then
        local rtt = dm.dcf.ping()
        if type(rtt) ~= "number" then
            -- give the bridge a few frames to come up before failing
            if frames > 120 then fail("ping() did not return a number") end
            return
        end
        print(string.format("ping ok: rtt=%.3f ms", rtt))
        phase = "send"
    elseif phase == "send" then
        if not sent then
            if not dm.dcf.send('{"v":1,"op":"ping"}') then
                fail("dm.dcf.send returned false")
            end
            sent = true
            print("sent control op {\"v\":1,\"op\":\"ping\"}")
        end
        phase = "poll"
    elseif phase == "poll" then
        local m = dm.dcf.poll()
        if m then
            local ll = m.levels_l and m.levels_l[1]
            local g  = m.gain and m.gain[1]
            local p  = m.pan and m.pan[1]
            print(string.format("telemetry: levels_l[1]=%s gain[1]=%s pan[1]=%s mute_mask=%s",
                tostring(ll), tostring(g), tostring(p), tostring(m.mute_mask)))
            if not approx(ll, 0.5, 1.0 / 255.0 + 1e-6) then fail("levels_l[1] != 0.5 (got " .. tostring(ll) .. ")") end
            if not approx(g, 0.75, 1.5 / 255.0 + 1e-6) then fail("gain[1] != 0.75 (got " .. tostring(g) .. ")") end
            if not approx(p, -0.5, 1.0 / 127.0 + 1e-6) then fail("pan[1] != -0.5 (got " .. tostring(p) .. ")") end
            if m.mute_mask ~= 2 then fail("mute_mask != 2 (got " .. tostring(m.mute_mask) .. ")") end
            print("PASS")
            dm.dcf.close()
            os.exit(0)
        end
    end

    dm.redraw()
end
