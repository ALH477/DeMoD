# DeMoD / Quanta — Soft-RT dev container

This directory is the Docker appliance for the [DeMoD/Quanta](../README.md) stack.
One `docker compose up` brings up the whole **soft-RT** audio engine, the DCF
bridges, a **browser-playable HLS monitor of the live engine over HydraMesh**, and
the WebAssembly UI.

Two images are provided:

- **Fat dev image** (`docker/Dockerfile`) — `nixos/nix` based, keeps the toolchain
  + Nix store so `nix develop` and fast rebuilds work. This is the default.
- **Slim runtime image** (`nix build .#docker-runtime`) — a pure-Nix
  `dockerTools` image with only the runtime closures (no toolchain, no source).

---

> ## ⚠ SOFT-REAL-TIME DEV CONTAINER — NOT REPRESENTATIVE OF REAL HARDWARE
>
> There is **no PREEMPT_RT kernel**, no `isolcpus`, no guaranteed `SCHED_FIFO` /
> `mlockall` inside a container. The engine's 1.33 ms (64-sample @ 48 kHz) budget
> is **not met here** — expect **much higher latency, jitter, and xruns** than a
> real DeMoD machine. The HLS monitor is a **24 kbps compressed** stream, not full
> fidelity.
>
> Use this for **building, wiring, and functional testing** — never for latency or
> throughput measurement, never for production audio. A larger JACK period
> (`JACK_PERIOD=1024`) is used on purpose. Run `entrypoint.sh doctor` for the
> live privilege + latency-posture readout.

---

## What it runs

```
HOST                                      CONTAINER (soft-RT, dev-only)
────────────────────────────────         ───────────────────────────────────────────────
browser ─ http://:8080 ──────────────►    python http.server ── web/ (WASM UI + /hls)
        ─ ws://:7000  ──────────────►      dcf-ws-bridge ─UDP─┐        └ /hls/monitor.m3u8
native demod-ui-dcf ─ UDP/DCF :47000 ►     (DCF mesh)         ├─► demod-remote-bridge ─┐
        ─ HLS <audio> (Mac/Win) ◄─────     dcf-ffmpeg ─ -f hls ─► web/hls/             │ control.sock
play ./out/out.wav ◄─ volume ────────      quanta-render                               ▼
                                           demod-dcf-audiocast ─DCF-Opus─► dcf-ffmpeg  demod-orchestrator
                                           jackd -d dummy ──► demod-rt ◄── SCHED_FIFO ──┘
```

- **WASM UI** at `http://localhost:8080/`; it joins the DCF mesh via
  `ws://localhost:7000` (`dcf-ws-bridge`).
- **HLS live monitor** at `http://localhost:8080/hls/monitor.m3u8` — the engine's
  output, cast over the **DCF-Audio** wire (24 kbps Opus, `codec_id 0`) by
  `demod-dcf-audiocast`, decoded by HydraMesh's `dcf-ffmpeg`, and served as
  browser-playable HLS (AAC/MPEG-TS). This is the "HydraMesh audio on fast
  hardware" path — it plays in any Mac/Windows browser.
- **DCF UDP** at `localhost:47000/udp` is the native mesh target for a host
  `demod-ui-dcf` desktop client.
- **WAV render** at `./out/out.wav` is the lossless, offline host-audio path.

### Host-audio matrix

| Path | Fidelity | Latency | Works on | Ships |
|------|----------|---------|----------|-------|
| **WAV render** (`render`) | lossless full-band | offline | all OS | ✅ |
| **DCF-Audio → HLS monitor** | 24 kbps Opus, mono | a few seconds (HLS) | all OS (browser) | ✅ |
| **Host JACK/PipeWire socket** (`linux-jack`) | full-band, real | near-RT | Linux host only | ✅ |

HydraMesh has **no raw-PCM/RTP path** — "audio transport" means the DCF-Audio
adapter (compressed ≤49.6 kbps blocks). The HLS monitor is the honest realisation
of that; for full fidelity use WAV render or the host-socket profile.

## Commands (entrypoint)

The image entrypoint dispatches on its first argument (default `serve`):

| Command | Does |
|---------|------|
| `serve` | full appliance: jackd → orchestrator + demod-rt → bridges → HLS monitor → UI |
| `stream` | HLS monitor only (jackd + caster + dcf-ffmpeg + UI), no orchestrator |
| `quanta-only` | bridges + WASM UI, **no engine** (no caps/ulimits needed) |
| `render <in> [out]` | Quanta `.qsc`/`.wav` → `${OUT}/out.wav` (lossless) |
| `analyze <in.wav> [out.qsc]` | Quanta matching-pursuit analyzer |
| `freeze <in.qsc> [out.dsp]` | Quanta Faust-freeze compiler (`--verify`) |
| `doctor` | RT-privilege report + soft-RT latency table |
| `test` | `make test` (needs faust + numpy, present in the fat image) |
| `shell` | drop into `nix develop` (fat dev image) |

## Build & run

```bash
docker compose -f docker/compose.yaml up --build            # full appliance (default)
docker compose -f docker/compose.yaml --profile quanta up   # codec + UI, no caps
docker compose -f docker/compose.yaml --profile hls up       # HLS monitor demo
docker compose -f docker/compose.yaml --profile linux-jack up  # share host audio (Linux)
```

First build takes ~10–20 min (Nix-built quanta + demod-rt + Haskell orchestrator +
Rust ws-bridge + HydraMesh dcf-ffmpeg + emscripten WASM UI). Rebuilds reuse the Docker
layer cache. The image is **self-contained** — the built binaries, the WASM UI, and the
health probe are baked into `/work`; the compose service deliberately does **not**
bind-mount the repo over `/work` (that would shadow them). For live-dev iteration use
the `shell` command (`nix develop`) or add your own mount at a different path.

Slim runtime image:

```bash
nix build .#docker-runtime && docker load < result   # loads demod-runtime:latest
docker run --rm -it --cap-add=SYS_NICE --cap-add=IPC_LOCK \
    --ulimit rtprio=95 --ulimit memlock=-1 --shm-size=512m \
    -p 8080:8080 -p 7000:7000 -p 47000:47000/udp demod-runtime:latest
```

`--shm-size=512m` is required: `jackd` and the orchestrator's IPC regions live in
`/dev/shm`, and Docker's 64 MB default SIGBUSes them on init. `docker compose`
sets this for you. The slim image serves a small HLS-monitor **landing page**
(the full WebAssembly control UI is only in the fat dev image and the Pages demo).

## Required runtime privileges

The orchestrator does pre-exec RT setup (`sched_setaffinity`, `SCHED_FIFO`,
`setrlimit(RLIMIT_MEMLOCK)`, `mlockall`) and **hard-exits** if any step fails
(`Supervisor.hs` 200/201/202/203; 204 if the `demod-rt` exec fails). So the engine
profiles carry:

```yaml
cap_add: [SYS_NICE, IPC_LOCK]
ulimits: { rtprio: 95, memlock: -1 }
```

A plain `docker run` **without** them makes the entrypoint print the exact required
`docker run` line and exit non-zero. Use the `quanta-only` command (or `--profile
quanta`) to boot without caps (bridges + WASM UI, no engine).

## Host-platform quickstart

### Mac / Windows (Docker Desktop in a VM, no native audio passthrough)

```bash
docker compose -f docker/compose.yaml up --build
# open       → http://localhost:8080/                    (hosted WASM UI)
# listen     → http://localhost:8080/hls/monitor.m3u8    (live engine, any browser)
# native DCF → localhost:47000/udp                        (if you also run demod-ui-dcf)
# WAV render → docker compose exec demod-dev \
#               /work/docker/entrypoint.sh render /work/path/to/in.wav   → ./out/out.wav
```

### Linux host

Use the same setup, or `--profile linux-jack` to share the host PipeWire/JACK socket
so the engine feeds real speakers instead of the dummy backend (adjust the socket
path in `compose.yaml` to your host).

## Environment knobs

| Var | Default | Notes |
|-----|---------|-------|
| `JACK_PERIOD` | `1024` | Larger than the 64-sample design point, on purpose. Lower = less latency, more xruns in soft-RT. |
| `DEMOD_DCF_PORT` | `47000` | UDP mesh port. |
| `DEMOD_DCF_BIND` | `0.0.0.0` | Mesh bind address (loopback `127.0.0.1` for host-only). |
| `RT_CORE` | `0` | Sched-affinity target. The orchestrator defaults to `4`; on small CPU sets core 4 is absent → EINVAL → exit 200, so the entrypoint uses `0`. |
| `OUT` | `/out` | Mounted volume for WAV renders. |
| `QSC_K`, `QSC_SNR`, `QSC_SEED` | `2048` / `45` / `0xDEC0DE` | Analyzer defaults for `render`/`analyze`. |

## Verification (manual)

```bash
# 1. WASM UI HTTP serve
curl -sSI http://localhost:8080/ | head -1                              # HTTP/1.0 200 OK
curl -sSI http://localhost:8080/demod-ui.wasm | grep -i content-type    # application/wasm
curl -fsS  http://localhost:8080/healthz                                # ok

# 2. HLS live monitor (grows over time; segments are fetchable)
curl -sS http://localhost:8080/hls/monitor.m3u8 | head

# 3. Engine health
docker compose exec demod-dev \
    python3 /work/audio-stack/bridge/test/control_probe.py /run/demod/control.sock
# → ok=True alive=True rt_status=running callbacks=<n>

# 4. Soft-RT honesty: under load the engine's xrun count is non-zero on shutdown
#    (expected — proves the warning). Also: `entrypoint.sh doctor` prints the table.

# 5. Missing-caps honesty: a bare `docker run` (no caps) prints the hint and exits.
docker build -f docker/Dockerfile -t demod-dev . && docker run --rm demod-dev serve
```

## Licensing

The docker glue (this directory) is **MPL-2.0**, matching the framework root. The
image *links* (as Nix-built binaries) components under different licenses:

| Component | License | Artifacts |
|-----------|---------|-----------|
| `quanta` codec | GPL-3.0-only OR DCSL | `quanta-{analyzer,render,freeze}` |
| `demod-rt`, orchestrator, **`demod-dcf-audiocast`** | GPL-3.0-only OR DCSL | `demod-rt`, `demod-orchestrator`, `demod-dcf-audiocast` |
| `demod-remote-bridge`, `dcf-ws-bridge`, `dm_dcf` | LGPL-3.0-only | the DCF bridges |
| HydraMesh `dcf-ffmpeg` / `dcf-radio` | GPL/LGPL (ffmpeg) + LGPL | the HLS server |
| WASM UI, framework root | MPL-2.0 | `web/demod-ui.{js,wasm}` + `index.html` |

`audio-stack/bridge/**` is an LGPL-3.0-only carve-out inside the otherwise-GPLv3
`audio-stack/` tree, **except** `demod-dcf-audiocast.c`, which links libjack + the
GPL engine world and carries the GPL-3.0-only OR DCSL header (see `../LICENSING.md`).

A *distributed* image must honor these licenses (offer corresponding source); this
is a **dev image**, intended to be built locally by each contributor.
