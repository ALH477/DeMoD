#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
#
# demod-quanta / DeMoD — soft-RT dev-appliance supervisor (multi-command).
#
#   ┌──────────────────────────────────────────────────────────────────────┐
#   │  ⚠  SOFT-REAL-TIME DEV CONTAINER — NOT REPRESENTATIVE OF REAL HARDWARE. │
#   │  No PREEMPT_RT kernel, no isolcpus, no guaranteed SCHED_FIFO/mlock.    │
#   │  The engine's 1.33 ms (64-sample @ 48 kHz) budget is NOT met here —    │
#   │  expect much higher latency, jitter, and xruns than a real DeMoD box.  │
#   │  The HLS monitor is a 24 kbps compressed stream, not full fidelity.    │
#   │  Use for building, wiring, functional testing — never for latency or   │
#   │  throughput measurement or production audio. A larger JACK period is  │
#   │  used on purpose.                                                      │
#   └──────────────────────────────────────────────────────────────────────┘
#
# Commands (first arg; default `serve`):
#   serve                boot the full soft-RT appliance: jackd → orchestrator +
#                        demod-rt → DCF bridges → HLS monitor caster → WASM UI.
#   stream               HLS monitor only (jackd + caster + dcf-ffmpeg + UI),
#                        no orchestrator/demod-rt — the fast-hardware audio demo.
#   quanta-only          bridges + WASM UI, no engine (no caps/ulimits needed).
#   render  <in> [out]   Quanta: .qsc|.wav → ${OUT}/out.wav (host-playable, lossless).
#   analyze <in.wav> [out.qsc]     Quanta matching-pursuit analyzer.
#   freeze  <in.qsc> [out.dsp]     Quanta Faust-freeze compiler.
#   doctor               print the RT-privilege report + soft-RT tradeoff table.
#   test                 run `make test` (needs faust + numpy from the flake).
#   shell                drop into `nix develop` (fat dev image only).
#   render_wav <in>      deprecated alias for `render`.
#
# Driven by environment (image / compose.yaml defaults):
#   DEMOD_DCF_PORT       UDP port the mesh listens on (default 47000)
#   DEMOD_DCF_BIND       mesh bind address (default 0.0.0.0 in-container)
#   DEMOD_CONTROL_SOCK   orchestrator ↔ bridge socket (default /run/demod/control.sock)
#   JACK_PERIOD          JACK period (default 1024; > the 64-sample design point on purpose)
#   HTTP_PORT            WASM UI + HLS static server port (default 8080)
#   WS_PORT              dcf-ws-bridge WebSocket port (default 7000)
#   OUT                  WAV render output dir, host-mounted (default /out)
#   DEMOD_SLIM=1         binaries are on PATH (the dockerTools runtime image), not
#                        under result-*/ links (the fat dev image).
#   DEMOD_WEB_SRC        read-only source of web/ (slim image); copied to a writable root.
set -euo pipefail

WORK=/work
PROBE="${DEMOD_PROBE:-$WORK/audio-stack/bridge/test/control_probe.py}"
ALL_PIDS=()
WEB=""   # writable web root, set by setup_web()

# ── binary resolution: prefer result-*/ links (fat dev image), else PATH (slim) ──
resolve() {  # resolve <binary> <result-link>
    local b=$1 link=$2
    if [[ -n "${DEMOD_SLIM:-}" ]]; then command -v "$b" 2>/dev/null && return 0; fi
    if [[ -x "$WORK/$link/bin/$b" ]]; then echo "$WORK/$link/bin/$b"; return 0; fi
    command -v "$b" 2>/dev/null && return 0
    return 1
}

Q_ANALYZER=""; Q_RENDER=""; Q_FREEZE=""
RT_BIN=""; ORCH=""; BRIDGE=""; WSB=""; CASTER=""; FFMPEG=""
resolve_bins() {
    Q_ANALYZER=$(resolve quanta-analyzer result-quanta || true)
    Q_RENDER=$(resolve   quanta-render   result-quanta || true)
    Q_FREEZE=$(resolve    quanta-freeze  result-quanta || true)
    RT_BIN=$(resolve demod-rt            result-rt      || true)
    ORCH=$(resolve   demod-orchestrator  result-orch    || true)
    BRIDGE=$(resolve demod-remote-bridge result-bridge  || true)
    WSB=$(resolve    dcf-ws-bridge       result-wsb     || true)
    CASTER=$(resolve demod-dcf-audiocast result-cast    || true)
    FFMPEG=$(resolve ffmpeg              result-ffmpeg  || true)
}

have() { command -v "$1" >/dev/null 2>&1; }
register_pid() { ALL_PIDS+=("$1"); }

# ── banners / doctor ───────────────────────────────────────────────────────────
warn_soft_rt() {
    cat >&2 <<'BANNER'
┌──────────────────────────────────────────────────────────────────────────────┐
│ ⚠  SOFT-REAL-TIME DEV CONTAINER — NOT REPRESENTATIVE OF REAL HARDWARE.        │
│   No PREEMPT_RT kernel, no isolcpus, no guaranteed SCHED_FIFO/mlock.         │
│   The 1.33 ms (64-sample @ 48 kHz) budget is NOT met here — expect higher    │
│   latency, jitter, and xruns than a real DeMoD machine. The HLS monitor is   │
│   24 kbps compressed, not full fidelity. Dev/wiring/functional use only.     │
└──────────────────────────────────────────────────────────────────────────────┘
BANNER
}

# CAP_IPC_LOCK = bit 14, CAP_SYS_NICE = bit 23.
have_caps() {
    local eff mask
    eff=$(grep '^CapEff:' /proc/self/status | cut -d: -f2 | tr -d ' \t')
    [[ -n "$eff" ]] || return 1
    mask=$(( (1 << 14) | (1 << 23) ))
    [[ $(( 0x$eff & mask )) -eq $mask ]]
}
check_rtprio() { local r; r=$(ulimit -r); [[ "${r:-0}" -ge 80 ]]; }

print_required_run_hint() {
    cat >&2 <<EOF

This container needs scheduler + memory privileges for the engine stack.
Re-run with the exact flags below (or use the \`quanta-only\` command to skip the
engine and run only the bridges + WASM UI):

    docker run --rm -it \\
        --cap-add=SYS_NICE --cap-add=IPC_LOCK \\
        --ulimit rtprio=95 --ulimit memlock=-1 \\
        --shm-size=512m \\
        -p 8080:8080 -p 7000:7000 -p 47000:47000/udp \\
        -v "\$PWD/out":/out \\
        <this-image>
EOF
}

doctor() {
    resolve_bins
    local caps="MISSING" rt="MISSING"
    have_caps    && caps="present (SYS_NICE + IPC_LOCK)"
    check_rtprio && rt="present (rtprio $(ulimit -r) ≥ 80)"
    cat >&2 <<EOF
DeMoD soft-RT doctor
────────────────────
  RLIMIT_RTPRIO   : $rt
  CAP_SYS_NICE/IPC: $caps
  jackd on PATH   : $(have jackd && echo yes || echo NO)
  demod-rt        : ${RT_BIN:-MISSING}
  orchestrator    : ${ORCH:-MISSING}
  caster/ffmpeg   : ${CASTER:-MISSING} / ${FFMPEG:-MISSING}

  Latency posture (why this is dev-only):
  ┌────────────────────┬──────────────────┬────────────────────┬──────────────┐
  │ path               │ period budget    │ SCHED_FIFO / mlock │ determinism  │
  ├────────────────────┼──────────────────┼────────────────────┼──────────────┤
  │ real DeMoD machine │ 64  ≈ 1.33 ms    │ yes (prio 80)      │ hard         │
  │ THIS container     │ ${JACK_PERIOD:-1024} samp (soft)   │ best-effort only   │ weak         │
  │ browser AudioWork. │ 128 ≈ 2.66 ms    │ no                 │ medium       │
  └────────────────────┴──────────────────┴────────────────────┴──────────────┘
EOF
    if ! have_caps || ! check_rtprio; then print_required_run_hint; fi
}

# ── web root (writable; serves the WASM UI, /healthz and /hls) ──────────────────
setup_web() {
    local src="${DEMOD_WEB_SRC:-$WORK/web}"
    WEB="${DEMOD_WEB:-}"
    if [[ -z "$WEB" ]]; then
        if [[ -w "$WORK/web" && -d "$WORK/web" ]]; then
            WEB="$WORK/web"                     # fat dev image: repo web/ is writable
        else
            WEB=/run/demod/web                  # slim image: copy the read-only source
            mkdir -p "$WEB"
            cp -r "$src/." "$WEB/" 2>/dev/null || true
        fi
    fi
    mkdir -p "$WEB/hls"
    printf 'ok\n' > "$WEB/healthz"
    # The full WASM control UI is only in the fat dev image (its build is impure —
    # emscripten fetches SDL2 + Lua from the network, so it can't be a sandboxed
    # nix build). When the bundle is absent (slim runtime image), serve a small
    # self-contained landing page with the live HLS monitor instead of a broken
    # index.html that 404s on demod-ui.js.
    if [[ ! -f "$WEB/demod-ui.wasm" ]]; then write_slim_index > "$WEB/index.html"; fi
}

write_slim_index() {
    cat <<'HTML'
<!DOCTYPE html>
<!-- SPDX-License-Identifier: MPL-2.0 -->
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>DeMoD runtime — soft-RT monitor</title>
<style>
  :root { --phosphor:#00f5d4; --bg:#0a0a0f; }
  html,body{margin:0;height:100%;background:var(--bg);color:#e8e8f0;
    font-family:ui-monospace,Menlo,Consolas,monospace}
  .wrap{max-width:760px;margin:0 auto;padding:2rem 1.25rem}
  h1{color:var(--phosphor);font-size:1.2rem;letter-spacing:.03em}
  .warn{border:1px solid #6b3;border-left:4px solid #fd0;background:#1a1a10;
    padding:.75rem 1rem;border-radius:6px;color:#ffd;font-size:.85rem;line-height:1.5}
  audio{width:100%;margin:1rem 0}
  a{color:var(--phosphor)} code{color:#9ff}
  .muted{color:#8a8aa0;font-size:.8rem;line-height:1.6}
</style></head><body><div class="wrap">
<h1>◈ DeMoD runtime — live monitor</h1>
<p class="warn">⚠ SOFT-REAL-TIME DEV CONTAINER — NOT REPRESENTATIVE OF REAL HARDWARE.
No PREEMPT_RT, no isolcpus, no guaranteed SCHED_FIFO/mlock. The HLS monitor below is a
<b>24&nbsp;kbps compressed</b> stream carried over the HydraMesh DCF-Audio wire — a monitor,
not full fidelity. Use WAV render or a host-audio socket for that.</p>
<h2 style="font-size:.95rem">Engine monitor (HLS over DCF-Audio)</h2>
<audio controls preload="none" src="/hls/monitor.m3u8"></audio>
<p class="muted">Native HLS plays in Safari; other browsers may need an HLS extension.
Playlist: <a href="/hls/monitor.m3u8"><code>/hls/monitor.m3u8</code></a> ·
Health: <a href="/healthz"><code>/healthz</code></a></p>
<p class="muted">This slim runtime image ships the headless engine + bridges + HLS monitor.
The full in-browser WebAssembly control UI is in the fat dev image
(<code>docker/Dockerfile</code>) and on the project's GitHub Pages demo.
DCF mesh: <code>udp:47000</code> · WebSocket relay: <code>ws://&lt;host&gt;:7000</code>.</p>
</div></body></html>
HTML
}

start_static_server() {
    have python3 || { echo "[entrypoint] python3 missing, no UI server" >&2; return 0; }
    # exec inside the backgrounded subshell so $! is the python pid we can reap.
    ( cd "$WEB" && exec python3 -m http.server --bind 0.0.0.0 "${HTTP_PORT:-8080}" ) >&2 &
    register_pid $!
    echo "[entrypoint] WASM UI + HLS:  http://localhost:${HTTP_PORT:-8080}/   (dir $WEB)"
}

start_bridges() {
    export DEMOD_DCF_BIND="${DEMOD_DCF_BIND:-0.0.0.0}"
    "$BRIDGE" >&2 & register_pid $!
    echo "[entrypoint] demod-remote-bridge:  DCF UDP ${DEMOD_DCF_BIND}:${DEMOD_DCF_PORT:-47000} ↔ control.sock + meters shm"
    "$WSB" --listen "0.0.0.0:${WS_PORT:-7000}" --udp-bind "0.0.0.0:0" >&2 & register_pid $!
    echo "[entrypoint] dcf-ws-bridge:        ws://0.0.0.0:${WS_PORT:-7000} ↔ UDP"
}

start_jackd() {
    have jackd || { echo "[entrypoint] jackd missing — no audio" >&2; return 1; }
    # -R realtime (best-effort; degrades silently), -m DON'T mlock buffers (fragile
    # under cgroup memlock even with --ulimit memlock=-1: can SIGBUS jackd on init).
    jackd -R -m -d dummy -r 48000 -p "${JACK_PERIOD:-1024}" >&2 & register_pid $!
    echo "[entrypoint] JACK:    jackd -R -d dummy -r 48000 -p ${JACK_PERIOD:-1024}"
    echo "[entrypoint] waiting for JACK to bind…"
    for _ in $(seq 1 40); do
        if [[ -S /tmp/jack-default/jack_0_0 || -S /tmp/jack-1000-0/jack_0 ]]; then break; fi
        sleep 0.25
    done
    sleep 1   # let the dummy driver register ports
}

start_engine() {
    [[ -n "$ORCH"   ]] || { echo "[entrypoint] orchestrator missing — engine disabled" >&2; return 1; }
    [[ -n "$RT_BIN" ]] || { echo "[entrypoint] demod-rt missing — engine disabled" >&2; return 1; }
    mkdir -p "$(dirname "${DEMOD_CONTROL_SOCK:-/run/demod/control.sock}")"
    "$ORCH" \
        --control-socket "${DEMOD_CONTROL_SOCK:-/run/demod/control.sock}" \
        --rt-binary      "$RT_BIN" \
        --rt-core        "${RT_CORE:-0}" >&2 & register_pid $!
    echo "[entrypoint] orchestrator: control.sock=${DEMOD_CONTROL_SOCK:-/run/demod/control.sock} rt-core=${RT_CORE:-0}"
    wait_for_rt
}

wait_for_rt() {
    local Sock="${DEMOD_CONTROL_SOCK:-/run/demod/control.sock}" line=""
    echo "[entrypoint] waiting for demod-rt to report 'running'…"
    for _ in $(seq 1 60); do
        line=$(python3 "$PROBE" "$Sock" 2>/dev/null || true)
        if [[ "$line" == *"rt_status=running"* ]]; then
            echo "[entrypoint] demod-rt reports running.  $line"; return 0
        fi
        sleep 0.5
    done
    echo "[entrypoint] WARN: demod-rt did not report running in ~30 s. Last: $line" >&2
    echo "    Continuing; bridges + UI are up. Use a real DeMoD machine for latency work." >&2
}

# HLS live monitor: cast audio over DCF-Audio (Opus), decode it with dcf-ffmpeg,
# and serve browser-playable HLS (AAC/MPEG-TS) from $WEB/hls. This is the "HydraMesh
# audio on fast hardware" path — a 24 kbps compressed monitor.
#   start_hls_monitor engine     cast the live demod-rt output (needs the engine)
#   start_hls_monitor tone       cast a synthesized test tone (no engine, cap-free)
start_hls_monitor() {
    [[ -n "$CASTER" && -n "$FFMPEG" ]] || { echo "[entrypoint] caster/ffmpeg missing — no HLS monitor" >&2; return 0; }
    local src="${1:-engine}" cast_args
    if [[ "$src" == tone ]]; then
        cast_args=(--test-tone --out stdout)
    else
        cast_args=(--connect demod-rt:out_L,demod-rt:out_R --out stdout)
    fi
    local hls="$WEB/hls/monitor.m3u8"
    ( "$CASTER" "${cast_args[@]}" \
        | "$FFMPEG" -hide_banner -loglevel warning -f dcf -i pipe:0 \
              -c:a aac -b:a 96k -ar 48000 -ac 1 \
              -f hls -hls_time 1 -hls_list_size 8 \
              -hls_flags delete_segments+append_list+omit_endlist \
              "$hls" ) >&2 &
    register_pid $!
    echo "[entrypoint] HLS monitor ($src): http://localhost:${HTTP_PORT:-8080}/hls/monitor.m3u8  (24 kbps Opus over DCF-Audio → AAC)"
}

# ── one-shot Quanta helpers ─────────────────────────────────────────────────────
cmd_render() {
    resolve_bins
    local src="${1:-${IN_QSC:-}}"
    [[ -n "$src" ]] || { echo "usage: render <in.qsc|in.wav> [out.wav]" >&2; return 2; }
    mkdir -p "${OUT:-/out}" 2>/dev/null || true
    local out_wav="${2:-${OUT:-/out}/out.wav}" qsc="$src"
    if [[ "${src,,}" == *.wav ]]; then
        qsc="${OUT:-/out}/score.qsc"
        echo "[render] analyzing $src → $qsc"
        "$Q_ANALYZER" "$src" -o "$qsc" --k "${QSC_K:-2048}" --snr "${QSC_SNR:-45}" --seed "${QSC_SEED:-0xDEC0DE}"
    fi
    echo "[render] rendering $qsc → $out_wav"
    "$Q_RENDER" "$qsc" --wav "$out_wav"
    echo "[render] done: $out_wav"
}
cmd_analyze() {
    resolve_bins
    local src="${1:?usage: analyze <in.wav> [out.qsc]}" out="${2:-${OUT:-/out}/score.qsc}"
    mkdir -p "$(dirname "$out")" 2>/dev/null || true
    "$Q_ANALYZER" "$src" -o "$out" --k "${QSC_K:-2048}" --snr "${QSC_SNR:-45}" --seed "${QSC_SEED:-0xDEC0DE}"
    echo "[analyze] $src → $out"
}
cmd_freeze() {
    resolve_bins
    local src="${1:?usage: freeze <in.qsc> [out.dsp]}" out="${2:-${OUT:-/out}/frozen.dsp}"
    mkdir -p "$(dirname "$out")" 2>/dev/null || true
    "$Q_FREEZE" "$src" -o "$out" --verify
    echo "[freeze] $src → $out"
}

cleanup() {
    local code=$?
    echo "[entrypoint] shutting down…" >&2
    for pid in "${ALL_PIDS[@]:-}"; do kill -TERM "$pid" 2>/dev/null || true; done
    sleep 1
    for pid in "${ALL_PIDS[@]:-}"; do kill -KILL "$pid" 2>/dev/null || true; done
    exit "$code"
}

# ── serve modes ────────────────────────────────────────────────────────────────
run_serve() {  # run_serve <full|stream|quanta-only>
    local mode=$1
    trap cleanup EXIT INT TERM
    warn_soft_rt
    resolve_bins
    setup_web
    mkdir -p "${OUT:-/out}" 2>/dev/null || true

    case "$mode" in
        full)
            if ! have_caps || ! check_rtprio; then
                echo "[entrypoint] missing RT caps/ulimits for the engine." >&2
                print_required_run_hint
                exit 1
            fi
            start_jackd || true
            start_engine || echo "[entrypoint] engine start failed; continuing with bridges + UI." >&2
            start_hls_monitor engine
            ;;
        stream)
            # HLS demo from a synthesized tone — no engine, no jackd, no caps.
            start_hls_monitor tone
            ;;
        quanta-only)
            echo "[entrypoint] quanta-only mode — no jackd/orchestrator/demod-rt." >&2
            ;;
    esac

    start_bridges
    start_static_server

    echo "[entrypoint] demod-dev appliance up ($mode):"
    echo "    WASM UI    http://localhost:${HTTP_PORT:-8080}/       (joins mesh via ws://localhost:${WS_PORT:-7000})"
    echo "    HLS mon.   http://localhost:${HTTP_PORT:-8080}/hls/monitor.m3u8"
    echo "    DCF UDP    ${DEMOD_DCF_PORT:-47000}/udp                (native demod-ui-dcf target)"
    echo "    WAV render docker exec <c> /work/docker/entrypoint.sh render <file>  → ${OUT:-/out}/out.wav"
    wait
}

main() {
    local cmd="${1:-serve}"; shift || true
    case "$cmd" in
        serve)               run_serve full ;;
        stream)              run_serve stream ;;
        quanta-only)         run_serve quanta-only ;;
        render|render_wav)   cmd_render "$@" ;;
        analyze)             cmd_analyze "$@" ;;
        freeze)              cmd_freeze "$@" ;;
        doctor)              doctor ;;
        test)                cd "$WORK" && exec nix develop -c make test ;;  # faust+numpy live in the dev shell
        shell)               cd "$WORK" && exec nix develop ;;
        -h|--help|help)
            sed -n '3,40p' "$0" | sed 's/^# \{0,1\}//' ;;
        *)
            echo "[entrypoint] unknown command '$cmd' (try: serve stream quanta-only render analyze freeze doctor test shell)" >&2
            exit 2 ;;
    esac
}
main "$@"
