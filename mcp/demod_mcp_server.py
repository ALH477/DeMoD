#!/usr/bin/env python3
# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 DeMoD LLC.
"""
demod_mcp_server.py — a Model Context Protocol server for working with the DeMoD
system: build it, render it headless (and see the screenshot), run its test
harnesses, and drive a live engine over the orchestrator control socket.

Pure Python standard library — no pip/npm deps. Speaks MCP over stdio
(newline-delimited JSON-RPC 2.0, protocol 2024-11-05). It is thin glue: tools
shell out to the repo's existing binaries/harnesses (nix, the bridge test
scripts, the DEMOD_SHOT headless render) and speak the control socket directly,
reusing the JSON-lines pattern from audio-stack/bridge/test/control_probe.py.

Install (points at your working tree so the tools can build/test it):
    claude mcp add demod -- python3 /path/to/DeMoD/mcp/demod_mcp_server.py
Requires `nix` on PATH for the build/test/render tools. Engine tools need a
running orchestrator control socket ($DEMOD_CONTROL_SOCK or /run/demod/control.sock).
"""
import base64
import atexit
import json
import os
import shutil
import socket
import struct
import subprocess
import sys
import tempfile
import time
import zlib

SERVER_NAME = "demod"
SERVER_VERSION = "0.1.0"
PROTOCOL_VERSION = "2024-11-05"

# A demod_stack_up-managed rig (orchestrator + demod-rt), persisted across tool
# calls: {"proc": Popen, "sock": str, "work": str}. None when nothing is running.
g_stack = None

# The repo is the parent of this mcp/ dir; override with DEMOD_REPO. Tools run
# against the working tree (they build/test/render it), not a store copy.
REPO = os.environ.get("DEMOD_REPO") or os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

MAX_OUT = 6000          # cap tool text output so it can't flood the agent
RENDER_MAX_W = 720      # downscale screenshots to keep the base64 small

# Examples safe to build/run (plain, non-DCF unless noted).
EXAMPLES = ["dsp_studio", "systems_viz", "hello", "dsp_panel", "card_launcher"]
# Flake packages the build tool will nix-build.
PACKAGES = ["demod-ui", "demod-rt", "demod-orchestrator", "demod-ui-dcf",
            "demod-remote-bridge", "dcf-ws-bridge", "quanta"]

# quanta codec defaults (analysis-to-synthesis: WAV -> .qsc score -> frozen .dsp).
QUANTA_K = 2048          # matching-pursuit atom budget
QUANTA_SNR = 45.0        # pursuit stop SNR (dB)
QUANTA_SEED = "0xDEC0DE" # residual noise LCG seed
# Test harnesses (bridge/test).
HARNESSES = {"loopback": "loopback.sh", "ws_loopback": "ws_loopback.sh",
             "engine_e2e": "engine_e2e.sh"}
# Control-socket ops an agent may issue (everything read-only + the safe writes).
ENGINE_OPS = {
    "ping", "get_health", "list_slots",
    "set_bpm", "set_gain", "set_param", "bypass_fx", "load_fx", "unload_fx",
    "synth.load", "synth.unload", "synth.mode", "synth.gain",
    "synth.note_on", "synth.note_off", "synth.all_notes_off",
    "set_slot_gain", "set_slot_pan", "set_slot_mute", "set_slot_solo",
}


# ── helpers ─────────────────────────────────────────────────────────────────
def _tail(s, n=MAX_OUT):
    s = s or ""
    return s if len(s) <= n else "…(truncated)…\n" + s[-n:]


def run(cmd, timeout=300, env=None, cwd=REPO):
    e = dict(os.environ)
    if env:
        e.update(env)
    try:
        p = subprocess.run(cmd, cwd=cwd, timeout=timeout, env=e,
                           capture_output=True, text=True)
        return p.returncode, p.stdout, p.stderr
    except subprocess.TimeoutExpired as ex:
        return 124, (ex.stdout or ""), (ex.stderr or "") + "\n[timed out]"
    except FileNotFoundError as ex:
        return 127, "", str(ex)


def control_request(sock_path, obj, timeout=3.0):
    """One JSON-lines request/reply on the orchestrator control socket."""
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(timeout)
    s.connect(sock_path)
    s.sendall((json.dumps(obj) + "\n").encode())
    buf = b""
    while b"\n" not in buf:
        chunk = s.recv(4096)
        if not chunk:
            break
        buf += chunk
    s.close()
    if not buf:
        raise RuntimeError("no reply from control socket")
    return json.loads(buf.split(b"\n", 1)[0].decode())


def control_path(arg):
    if arg:
        return arg
    if g_stack and g_stack["proc"].poll() is None:
        return g_stack["sock"]        # prefer a demod_stack_up rig if one's running
    return os.environ.get("DEMOD_CONTROL_SOCK") or "/run/demod/control.sock"


# ── PPM(P6) -> PNG, pure stdlib (zlib), with nearest-neighbour downscale ─────
def _read_ppm(data):
    if data[:2] != b"P6":
        raise ValueError("not a P6 PPM")
    i, toks = 2, []
    while len(toks) < 3:
        while i < len(data) and data[i:i + 1].isspace():
            i += 1
        if data[i:i + 1] == b"#":
            while i < len(data) and data[i:i + 1] != b"\n":
                i += 1
            continue
        j = i
        while j < len(data) and not data[j:j + 1].isspace():
            j += 1
        toks.append(data[i:j])
        i = j
    w, h, _mx = int(toks[0]), int(toks[1]), int(toks[2])
    i += 1  # single whitespace after maxval
    return w, h, data[i:i + w * h * 3]


def _downscale(w, h, rgb, max_w):
    if w <= max_w:
        return w, h, rgb
    nw = max_w
    nh = max(1, h * max_w // w)
    out = bytearray(nw * nh * 3)
    for y in range(nh):
        sy = (y * h // nh) * w
        row = y * nw
        for x in range(nw):
            si = (sy + x * w // nw) * 3
            di = (row + x) * 3
            out[di:di + 3] = rgb[si:si + 3]
    return nw, nh, bytes(out)


def _png_chunk(tag, data):
    return (struct.pack(">I", len(data)) + tag + data
            + struct.pack(">I", zlib.crc32(tag + data) & 0xffffffff))


def rgb_to_png(w, h, rgb):
    raw = bytearray()
    stride = w * 3
    for y in range(h):
        raw.append(0)                       # filter type 0 (none)
        raw += rgb[y * stride:(y + 1) * stride]
    comp = zlib.compress(bytes(raw), 9)
    ihdr = struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0)  # 8-bit RGB
    return (b"\x89PNG\r\n\x1a\n" + _png_chunk(b"IHDR", ihdr)
            + _png_chunk(b"IDAT", comp) + _png_chunk(b"IEND", b""))


# ── tools ────────────────────────────────────────────────────────────────────
def text(s):
    return {"content": [{"type": "text", "text": _tail(s)}]}


def err(s):
    return {"content": [{"type": "text", "text": _tail(s)}], "isError": True}


def tool_build(a):
    pkg = a.get("package", "demod-ui")
    if pkg not in PACKAGES:
        return err("unknown package %r; choose one of: %s" % (pkg, ", ".join(PACKAGES)))
    rc, out, e = run(["nix", "build", ".#" + pkg, "-L", "--no-link"], timeout=1200)
    head = "nix build .#%s -> %s\n" % (pkg, "OK" if rc == 0 else "FAIL (rc=%d)" % rc)
    return (text if rc == 0 else err)(head + _tail(e or out))


def tool_test(a):
    which = a.get("harness", "loopback")
    if which not in HARNESSES:
        return err("unknown harness %r; choose: %s" % (which, ", ".join(HARNESSES)))
    rc, out, e = run(["bash", "audio-stack/bridge/test/" + HARNESSES[which]], timeout=600)
    body = out + ("\n" + e if e else "")
    verdict = "SKIP" if "SKIP:" in body else ("PASS" if rc == 0 else "FAIL")
    return (text if rc == 0 else err)("%s: %s\n%s" % (HARNESSES[which], verdict, _tail(body)))


def tool_render(a):
    ex = a.get("example", "dsp_studio")
    frame = int(a.get("frame", 90))
    if ex not in EXAMPLES:
        return err("unknown example %r; choose: %s" % (ex, ", ".join(EXAMPLES)))
    shot = "/tmp/demod_mcp_shot.ppm"
    try:
        os.path.exists(shot) and os.remove(shot)
    except OSError:
        pass
    inner = ("make >/dev/null 2>&1; SDL_VIDEODRIVER=dummy SDL_AUDIODRIVER=dummy "
             "DEMOD_SHOT=%s DEMOD_SHOT_FRAME=%d timeout 25 ./demod-ui examples/%s.lua"
             % (shot, frame, ex))
    rc, out, e = run(["nix", "develop", "--command", "bash", "-c", inner], timeout=400)
    if not os.path.exists(shot):
        return err("no frame produced for %s (rc=%d)\n%s" % (ex, rc, _tail(e or out)))
    with open(shot, "rb") as f:
        w, h, rgb = _read_ppm(f.read())
    w, h, rgb = _downscale(w, h, rgb, RENDER_MAX_W)
    png = rgb_to_png(w, h, rgb)
    return {"content": [
        {"type": "text", "text": "rendered examples/%s.lua at frame %d (%dx%d)" % (ex, frame, w, h)},
        {"type": "image", "data": base64.b64encode(png).decode(), "mimeType": "image/png"},
    ]}


def tool_smoke(a):
    ex = a.get("example", "dsp_studio")
    if ex not in EXAMPLES:
        return err("unknown example %r; choose: %s" % (ex, ", ".join(EXAMPLES)))
    inner = ("make >/dev/null 2>&1; SDL_VIDEODRIVER=dummy SDL_AUDIODRIVER=dummy "
             "DEMOD_SHOT=/tmp/demod_smoke.ppm DEMOD_SHOT_FRAME=60 timeout 15 ./demod-ui examples/%s.lua" % ex)
    rc, out, e = run(["nix", "develop", "--command", "bash", "-c", inner], timeout=300)
    body = (out + "\n" + e)
    bad = [ln for ln in body.splitlines()
           if any(k in ln.lower() for k in ("error", "attempt to", "traceback", "stack traceback"))]
    if rc == 0 and not bad:
        return text("smoke OK: examples/%s.lua ran headless with no Lua errors" % ex)
    return err("smoke FAIL (rc=%d) for %s:\n%s" % (rc, ex, _tail("\n".join(bad) or body)))


def tool_engine_health(a):
    try:
        r = control_request(control_path(a.get("socket")), {"v": 1, "id": "h", "op": "get_health"})
    except Exception as ex:  # noqa: BLE001 — surface any connect/parse failure to the agent
        return err("engine unreachable at %s: %s" % (control_path(a.get("socket")), ex))
    return text(json.dumps(r, indent=2))


def tool_engine_list_slots(a):
    try:
        r = control_request(control_path(a.get("socket")), {"v": 1, "id": "s", "op": "list_slots"})
    except Exception as ex:  # noqa: BLE001
        return err("engine unreachable at %s: %s" % (control_path(a.get("socket")), ex))
    return text(json.dumps(r, indent=2))


def tool_engine_op(a):
    op = a.get("op", "")
    if op not in ENGINE_OPS:
        return err("op %r not allowed; choose one of: %s" % (op, ", ".join(sorted(ENGINE_OPS))))
    req = {"v": 1, "id": "op", "op": op}
    params = a.get("params") or {}
    if isinstance(params, dict):
        req.update(params)
    try:
        r = control_request(control_path(a.get("socket")), req)
    except Exception as ex:  # noqa: BLE001
        return err("engine unreachable at %s: %s" % (control_path(a.get("socket")), ex))
    out = json.dumps(r, indent=2)
    return err(out) if r.get("ok") is False else text(out)


# ── managed rig bring-up (demod_stack_up / _down) ────────────────────────────
def _rtprio():
    rc, out, _ = run(["bash", "-c", "ulimit -r"], timeout=10)
    v = (out or "").strip()
    if v == "unlimited":
        return 10 ** 9
    try:
        return int(v)
    except ValueError:
        return 0


def _resolve_pwjack():
    rc, out, _ = run(["nix", "shell", "nixpkgs#pipewire.jack", "--command",
                      "bash", "-c", "command -v pw-jack"], timeout=600)
    p = (out or "").strip().splitlines()[-1] if out.strip() else ""
    return p if p and os.path.exists(p) else None


def _health(sock):
    return control_request(sock, {"v": 1, "id": "h", "op": "get_health"})


def _rt_running(h):
    return any(c.get("name") == "demod-rt" and c.get("status") == "running"
               for c in (h.get("data") or {}).get("children", []))


def tool_stack_up(a):
    """Bring up a real orchestrator + demod-rt on JACK so the engine tools can
    drive it. Guarded: returns a SKIP message where JACK/RT aren't available."""
    global g_stack
    if g_stack and g_stack["proc"].poll() is None:
        try:
            h = _health(g_stack["sock"])
        except Exception:  # noqa: BLE001
            h = {}
        return text("stack already up. control socket: %s\n%s"
                    % (g_stack["sock"], json.dumps(h, indent=2)))

    if _rtprio() < 80:
        return text("SKIP: real engine needs rtprio >= 80 (ulimit -r). Use the harnesses instead.")
    if run(["pgrep", "-x", "pipewire"], timeout=10)[0] != 0:
        return text("SKIP: no JACK server (no running PipeWire). Start one, or use demod_test.")
    pwjack = _resolve_pwjack()
    if not pwjack:
        return text("SKIP: pw-jack (nixpkgs#pipewire.jack) unavailable.")

    work = tempfile.mkdtemp(prefix="demod-mcp-stack-")
    for pkg, link in (("demod-orchestrator", "orch"), ("demod-rt", "rt")):
        if run(["nix", "build", ".#" + pkg, "-o", os.path.join(work, link)], timeout=1800)[0] != 0:
            shutil.rmtree(work, ignore_errors=True)
            return err("nix build .#%s failed" % pkg)
    orch = os.path.join(work, "orch/bin/demod-orchestrator")
    rt = os.path.join(work, "rt/bin/demod-rt")
    sock = os.path.join(work, "control.sock")

    logf = open(os.path.join(work, "orch.log"), "w")
    proc = subprocess.Popen([pwjack, orch, "--control-socket", sock, "--rt-binary", rt],
                            cwd=REPO, stdout=logf, stderr=subprocess.STDOUT)
    health = None
    for _ in range(80):
        time.sleep(0.25)
        if proc.poll() is not None:
            break
        if os.path.exists(sock):
            try:
                h = _health(sock)
                if _rt_running(h):
                    health = h
                    break
            except Exception:  # noqa: BLE001 — socket may not be accepting yet
                pass
    if not health:
        try:
            proc.terminate()
        except Exception:  # noqa: BLE001
            pass
        with open(os.path.join(work, "orch.log")) as f:
            tail = _tail(f.read(), 2000)
        shutil.rmtree(work, ignore_errors=True)
        return err("stack failed to reach 'running'.\norch.log:\n" + tail)

    g_stack = {"proc": proc, "sock": sock, "work": work}
    return text("stack up. demod_engine_* now target it by default.\ncontrol socket: %s\n%s"
                % (sock, json.dumps(health, indent=2)))


def _teardown():
    global g_stack
    if not g_stack:
        return "no stack running"
    proc = g_stack["proc"]
    try:
        proc.terminate()          # SIGTERM -> orchestrator cleanly stops demod-rt
        proc.wait(timeout=5)
    except Exception:  # noqa: BLE001
        try:
            proc.kill()
        except Exception:  # noqa: BLE001
            pass
    run(["pkill", "-f", "demod-rt --core"], timeout=10)
    shutil.rmtree(g_stack["work"], ignore_errors=True)
    g_stack = None
    return "stack down"


def tool_stack_down(a):
    return text(_teardown())


atexit.register(lambda: g_stack and _teardown())


# ── quanta codec (analysis-to-synthesis) ─────────────────────────────────────
def _resolve_path(p):
    """Absolute path, or one relative to the repo root; None if it doesn't exist."""
    if not p:
        return None
    q = p if os.path.isabs(p) else os.path.join(REPO, p)
    return q if os.path.exists(q) else None


def _quanta_bins():
    """nix build .#quanta and return its bin/ dir. Raises RuntimeError on failure."""
    rc, out, e = run(["nix", "build", ".#quanta", "--no-link", "--print-out-paths"],
                     timeout=900)
    paths = [ln for ln in (out or "").splitlines() if ln.strip()]
    if rc != 0 or not paths:
        raise RuntimeError("nix build .#quanta failed (rc=%d)\n%s" % (rc, _tail(e or out)))
    bind = os.path.join(paths[-1].strip(), "bin")
    if not os.path.isdir(bind):
        raise RuntimeError("quanta build produced no bin/ at %s" % bind)
    return bind


def tool_quanta_compile(a):
    """WAV -> matching-pursuit .qsc score -> (optional) frozen Faust .dsp."""
    wav = _resolve_path(a.get("wav"))
    if not wav:
        return err("wav not found: %r (give an absolute path or one relative to the repo root)"
                   % a.get("wav"))
    k = int(a.get("k", QUANTA_K))
    snr = float(a.get("snr", QUANTA_SNR))
    seed = str(a.get("seed", QUANTA_SEED))
    do_freeze = a.get("freeze", True)
    try:
        bind = _quanta_bins()
    except Exception as ex:  # noqa: BLE001 — surface build failure to the agent
        return err(str(ex))
    work = tempfile.mkdtemp(prefix="demod-mcp-quanta-")
    qsc = os.path.join(work, "score.qsc")
    rc, out, e = run([os.path.join(bind, "quanta-analyzer"), wav, "-o", qsc,
                      "--k", str(k), "--snr", str(snr), "--seed", seed], timeout=600)
    if rc != 0 or not os.path.exists(qsc):
        shutil.rmtree(work, ignore_errors=True)
        return err("quanta-analyzer failed (rc=%d)\n%s" % (rc, _tail(e or out)))
    report = ("quanta-analyzer %s  (K=%d snr=%.0f seed=%s)\n%s"
              % (os.path.basename(wav), k, snr, seed, (e or out).strip()))
    if do_freeze:
        dsp = os.path.join(work, "frozen.dsp")
        rc2, out2, e2 = run([os.path.join(bind, "quanta-freeze"), qsc, "-o", dsp], timeout=180)
        if rc2 != 0 or not os.path.exists(dsp):
            return err(report + "\n\nquanta-freeze failed (rc=%d)\n%s" % (rc2, _tail(e2 or out2)))
        report += ("\n\nquanta-freeze -> %s\n%s\n  .qsc %d B   .dsp %d B"
                   % (dsp, (e2 or out2).strip(), os.path.getsize(qsc), os.path.getsize(dsp)))
    else:
        report += "\n\nscore: %s (%d B)" % (qsc, os.path.getsize(qsc))
    return text(report)


def tool_quanta_verify(a):
    """Run the quanta gate loop (null test + M0 tonal) and report PASS/FAIL."""
    k = int(a.get("k", 400))
    inner = ("cd quanta && make clean >/dev/null 2>&1; make >/dev/null 2>&1 && "
             "K=%d bash test/run.sh" % k)
    rc, out, e = run(["nix", "develop", "--command", "bash", "-c", inner], timeout=1200)
    body = out + ("\n" + e if e else "")
    keep = [ln for ln in body.splitlines() if any(
        s in ln for s in ("NULL GATE", "null:", "gate:", "lsd:", "ALL GATES",
                          "residual layer trim", "voice cull", "FAIL", "Error"))]
    ok_ = rc == 0 and "ALL GATES PASS" in body
    head = "quanta gates: %s\n" % ("PASS" if ok_ else "FAIL")
    return (text if ok_ else err)(head + _tail("\n".join(keep) or body))


def tool_quanta_render(a):
    """Render the quanta score-browser panel headless -> PNG. With `wav`, compile
    that file first and show its score; otherwise show the in-tree sample score."""
    frame = int(a.get("frame", 90))
    shot = "/tmp/demod_mcp_quanta.ppm"
    try:
        os.path.exists(shot) and os.remove(shot)
    except OSError:
        pass
    panel = os.path.join(REPO, "quanta", "ui", "quanta_panel.lua")
    demodui = os.path.join(REPO, "demod-ui")
    cwd_for_panel = os.path.join(REPO, "quanta")   # panel dofile()s ui/score.lua from cwd
    note = "in-tree sample score"
    if a.get("wav"):
        wav = _resolve_path(a.get("wav"))
        if not wav:
            return err("wav not found: %r" % a.get("wav"))
        try:
            bind = _quanta_bins()
        except Exception as ex:  # noqa: BLE001
            return err(str(ex))
        work = tempfile.mkdtemp(prefix="demod-mcp-qrender-")
        os.makedirs(os.path.join(work, "ui"), exist_ok=True)
        qsc = os.path.join(work, "score.qsc")
        rc, out, e = run([os.path.join(bind, "quanta-analyzer"), wav, "-o", qsc,
                          "--k", str(int(a.get("k", QUANTA_K))),
                          "--snr", str(float(a.get("snr", QUANTA_SNR)))], timeout=600)
        if rc != 0 or not os.path.exists(qsc):
            shutil.rmtree(work, ignore_errors=True)
            return err("quanta-analyzer failed (rc=%d)\n%s" % (rc, _tail(e or out)))
        rc2, o2, e2 = run([os.path.join(bind, "quanta-freeze"), qsc,
                           "-o", os.path.join(work, "frozen.dsp"),
                           "--lua", os.path.join(work, "ui", "score.lua")], timeout=180)
        if rc2 != 0 or not os.path.exists(os.path.join(work, "ui", "score.lua")):
            shutil.rmtree(work, ignore_errors=True)
            return err("quanta-freeze --lua failed (rc=%d)\n%s" % (rc2, _tail(e2 or o2)))
        cwd_for_panel = work
        note = "compiled score of %s" % os.path.basename(wav)
    inner = ("cd %s && make >/dev/null 2>&1; cd %s && "
             "SDL_VIDEODRIVER=dummy SDL_AUDIODRIVER=dummy DEMOD_SHOT=%s DEMOD_SHOT_FRAME=%d "
             "timeout 25 %s %s" % (REPO, cwd_for_panel, shot, frame, demodui, panel))
    rc, out, e = run(["nix", "develop", "--command", "bash", "-c", inner], timeout=400)
    if not os.path.exists(shot):
        return err("no frame produced (rc=%d)\n%s" % (rc, _tail(e or out)))
    with open(shot, "rb") as f:
        w, h, rgb = _read_ppm(f.read())
    w, h, rgb = _downscale(w, h, rgb, RENDER_MAX_W)
    png = rgb_to_png(w, h, rgb)
    return {"content": [
        {"type": "text", "text": "quanta panel (%s) at frame %d (%dx%d)" % (note, frame, w, h)},
        {"type": "image", "data": base64.b64encode(png).decode(), "mimeType": "image/png"},
    ]}


TOOLS = [
    {"name": "demod_build", "description": "Build a DeMoD component with nix (demod-ui, demod-rt, demod-orchestrator, demod-remote-bridge, dcf-ws-bridge, demod-ui-dcf).",
     "inputSchema": {"type": "object", "properties": {"package": {"type": "string", "enum": PACKAGES}}},
     "_fn": tool_build},
    {"name": "demod_test", "description": "Run a bridge/transport test harness and report PASS/FAIL/SKIP. engine_e2e drives the real orchestrator+demod-rt (self-skips without JACK/RT).",
     "inputSchema": {"type": "object", "properties": {"harness": {"type": "string", "enum": list(HARNESSES)}}},
     "_fn": tool_test},
    {"name": "demod_render", "description": "Render an example UI headless (DEMOD_SHOT) and return a PNG screenshot you can see.",
     "inputSchema": {"type": "object", "properties": {"example": {"type": "string", "enum": EXAMPLES}, "frame": {"type": "integer"}}},
     "_fn": tool_render},
    {"name": "demod_smoke", "description": "Run an example headless for a moment and confirm it boots with no Lua errors.",
     "inputSchema": {"type": "object", "properties": {"example": {"type": "string", "enum": EXAMPLES}}},
     "_fn": tool_smoke},
    {"name": "demod_quanta_compile", "description": "DeMoD Quanta codec: compile a WAV into a matching-pursuit .qsc score and (by default) freeze it to a static Faust .dsp. Reports atoms/voices/residual dB + artifact paths.",
     "inputSchema": {"type": "object",
                     "properties": {"wav": {"type": "string", "description": "input WAV path (absolute or relative to the repo root)"},
                                    "k": {"type": "integer", "description": "matching-pursuit atom budget (default 2048)"},
                                    "snr": {"type": "number", "description": "pursuit stop SNR in dB (default 45)"},
                                    "seed": {"type": "string", "description": "residual noise seed (default 0xDEC0DE)"},
                                    "freeze": {"type": "boolean", "description": "also emit the frozen .dsp (default true)"}},
                     "required": ["wav"]},
     "_fn": tool_quanta_compile},
    {"name": "demod_quanta_verify", "description": "Run the quanta release gates: the null test (frozen Faust artifact vs C reference player, <= -120 dBFS) and the M0 tonal LSD gate. Reports PASS/FAIL with the dB figures. Needs faust + numpy (in the flake devShell).",
     "inputSchema": {"type": "object", "properties": {"k": {"type": "integer", "description": "hybrid-corpus atom budget for the loop (default 400)"}}},
     "_fn": tool_quanta_verify},
    {"name": "demod_quanta_render", "description": "Render the quanta score-browser panel headless and return a PNG. With `wav`, compile that file first and show its score; otherwise show the in-tree sample score.",
     "inputSchema": {"type": "object",
                     "properties": {"wav": {"type": "string", "description": "optional WAV to compile and display"},
                                    "frame": {"type": "integer", "description": "frame to capture (default 90)"},
                                    "k": {"type": "integer"}, "snr": {"type": "number"}}},
     "_fn": tool_quanta_render},
    {"name": "demod_stack_up", "description": "Bring up a real rig (orchestrator + demod-rt on JACK, via pw-jack) that the demod_engine_* tools then drive by default. Guarded: SKIPs cleanly where JACK/RT privileges are absent. Persists until demod_stack_down.",
     "inputSchema": {"type": "object", "properties": {}},
     "_fn": tool_stack_up},
    {"name": "demod_stack_down", "description": "Tear down the rig started by demod_stack_up (stops demod-rt + orchestrator, cleans up).",
     "inputSchema": {"type": "object", "properties": {}},
     "_fn": tool_stack_down},
    {"name": "demod_engine_health", "description": "Query a live orchestrator's get_health over its control socket (demod-rt liveness, callbacks, xruns, children). Uses the demod_stack_up rig if one is running.",
     "inputSchema": {"type": "object", "properties": {"socket": {"type": "string", "description": "control socket path; defaults to $DEMOD_CONTROL_SOCK or /run/demod/control.sock"}}},
     "_fn": tool_engine_health},
    {"name": "demod_engine_list_slots", "description": "List the engine's FX/synth slots (loaded/path/bypassed) over the control socket.",
     "inputSchema": {"type": "object", "properties": {"socket": {"type": "string"}}},
     "_fn": tool_engine_list_slots},
    {"name": "demod_engine_op", "description": "Send one control op to a live engine (set_bpm, set_param, load_fx, bypass_fx, synth.*, set_slot_*). Returns the orchestrator's reply.",
     "inputSchema": {"type": "object",
                     "properties": {"op": {"type": "string", "enum": sorted(ENGINE_OPS)},
                                    "params": {"type": "object", "description": "op args, e.g. {\"bpm\":128} or {\"slot\":0,\"idx\":1,\"value\":0.5}"},
                                    "socket": {"type": "string"}},
                     "required": ["op"]},
     "_fn": tool_engine_op},
]
TOOL_BY_NAME = {t["name"]: t for t in TOOLS}

RESOURCES = [
    {"uri": "demod://skill", "name": "SKILL.md — dm.* Lua API reference",
     "description": "The authoritative dm.* API + 'common mistakes' for writing DeMoD Lua.",
     "mimeType": "text/markdown", "_path": "SKILL.md"},
    {"uri": "demod://quanta-spec", "name": "quanta/docs/SPEC.md — Quanta codec spec",
     "description": "QSC score format + the analysis-to-synthesis / Faust-freeze engine spec.",
     "mimeType": "text/markdown", "_path": "quanta/docs/SPEC.md"},
    {"uri": "demod://control-ops", "name": "Control-socket op vocabulary",
     "description": "The JSON-lines ops the orchestrator accepts.",
     "mimeType": "text/markdown", "_gen": lambda: "# Control-socket ops\n\n" +
     "\n".join("- `%s`" % o for o in sorted(ENGINE_OPS)) +
     "\n\nEnvelope: `{\"v\":1,\"op\":\"<op>\", ...args}`\\n per line over the AF_UNIX socket."},
]


# ── JSON-RPC / MCP dispatch ──────────────────────────────────────────────────
def handle(req):
    method = req.get("method")
    rid = req.get("id")
    if method == "initialize":
        return ok(rid, {"protocolVersion": PROTOCOL_VERSION,
                        "capabilities": {"tools": {}, "resources": {}},
                        "serverInfo": {"name": SERVER_NAME, "version": SERVER_VERSION}})
    if method in ("notifications/initialized", "notifications/cancelled"):
        return None  # notification: no response
    if method == "ping":
        return ok(rid, {})
    if method == "tools/list":
        return ok(rid, {"tools": [{k: t[k] for k in ("name", "description", "inputSchema")} for t in TOOLS]})
    if method == "tools/call":
        p = req.get("params") or {}
        name = p.get("name")
        t = TOOL_BY_NAME.get(name)
        if not t:
            return jerr(rid, -32602, "unknown tool: %s" % name)
        try:
            return ok(rid, t["_fn"](p.get("arguments") or {}))
        except Exception as ex:  # noqa: BLE001 — never crash the server on a tool error
            return ok(rid, err("%s failed: %s" % (name, ex)))
    if method == "resources/list":
        return ok(rid, {"resources": [{k: r[k] for k in ("uri", "name", "description", "mimeType")} for r in RESOURCES]})
    if method == "resources/read":
        uri = (req.get("params") or {}).get("uri")
        for r in RESOURCES:
            if r["uri"] == uri:
                body = r["_gen"]() if "_gen" in r else _read_file(r["_path"])
                return ok(rid, {"contents": [{"uri": uri, "mimeType": r["mimeType"], "text": body}]})
        return jerr(rid, -32602, "unknown resource: %s" % uri)
    return jerr(rid, -32601, "method not found: %s" % method)


def _read_file(rel):
    try:
        with open(os.path.join(REPO, rel), "r") as f:
            return f.read()
    except OSError as ex:
        return "(unavailable: %s)" % ex


def ok(rid, result):
    return {"jsonrpc": "2.0", "id": rid, "result": result}


def jerr(rid, code, message):
    return {"jsonrpc": "2.0", "id": rid, "error": {"code": code, "message": message}}


def main():
    out = sys.stdout
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            req = json.loads(line)
        except json.JSONDecodeError:
            continue
        resp = handle(req)
        if resp is not None:
            out.write(json.dumps(resp) + "\n")
            out.flush()


if __name__ == "__main__":
    main()
