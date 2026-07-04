# demod-dev — DeMoD / Quanta soft-RT dev container

> **⚠ SOFT-REAL-TIME DEV CONTAINER — NOT REPRESENTATIVE OF REAL HARDWARE**
>
> No PREEMPT_RT kernel, no `isolcpus`, no guaranteed `SCHED_FIFO` / `mlockall`
> inside a container. The engine's 1.33 ms (64-sample @ 48 kHz) budget is **not
> met here** — expect much higher latency, jitter, and xruns than a real DeMoD
> machine. Use for **building, wiring, and functional testing only** — never for
> latency measurement, throughput benchmarking, or production audio.

This is the **development appliance** image for the
[DeMoD / Quanta](https://github.com/ALH477/DeMoD) stack — a single Nix-built
container that brings up:

- the **Quanta codec** (`quanta-analyzer` / `quanta-render` / `quanta-freeze`)
- the **JACK-soft-RT audio engine** (`demod-rt` + the Haskell `demod-orchestrator`)
- both **DCF remote bridges** (UDP ⇄ control-socket, and WebSocket ⇄ UDP for the
  browser)
- a **browser-playable HLS monitor of the live engine over HydraMesh** — the engine
  output cast over the DCF-Audio wire (24 kbps Opus) and served as HLS at
  `/hls/monitor.m3u8` (`demod-dcf-audiocast` + HydraMesh `dcf-ffmpeg`)
- the **browser (WASM) UI** `demod-ui`, served over HTTP

The entrypoint is multi-command: `serve` (default), `stream` (HLS only),
`quanta-only`, `render` / `analyze` / `freeze`, and `doctor` (privilege + latency
report).

### Tags

| Tag | Image | Contents |
|-----|-------|----------|
| `alh477/demod-dev:latest` | **fat dev** (`nixos/nix`) | full toolchain + Nix store (`nix develop`, rebuilds), the full in-browser **WASM control UI**, and the whole engine stack. |
| `alh477/demod-dev:runtime` | **slim runtime** (`dockerTools`) | only the runtime closures — engine, bridges, HLS monitor, Quanta CLIs — plus an HLS-monitor landing page. No toolchain, much smaller. |

Both run the same multi-command entrypoint; pick `:runtime` for deployment-shaped use
and `:latest` for development. (`:runtime` is also reproducible from source with
`nix build .#docker-runtime`.)

Source, full docs, and the normative spec live in the GitHub repo:

> **Source** — <https://github.com/ALH477/DeMoD>
> **Top-level **`README.md`** there carries the project overview, licensing, and
> the verified-results table.`docker/README.md` in the repo documents the
> container's design and the build knobs in depth; this Docker Hub page is the
> short-form quickstart.

---

## TL;DR — pull and run

```bash
docker pull alh477/demod-dev:latest

# Needed: scheduler + memory privileges (the orchestrator hard-exits 200–203
# without SYS_NICE / IPC_LOCK). Map three ports and the WAV-out volume:
docker run --rm -it \
  --cap-add=SYS_NICE --cap-add=IPC_LOCK \
  --ulimit rtprio=95 --ulimit memlock=-1 \
  --shm-size=512m \
  -p 8080:8080 -p 7000:7000 -p 47000:47000/udp \
  -v "$PWD/out:/out" \
  alh477/demod-dev:latest
```

`--shm-size=512m` is required — `jackd` and the orchestrator's IPC regions live in
`/dev/shm`, and Docker's 64 MB default SIGBUSes them on init.

Then:
- open <http://localhost:8080/> — the hosted **WASM UI** (joins the DCF mesh via
  `ws://localhost:7000`)
- listen to the **live engine** at <http://localhost:8080/hls/monitor.m3u8> — a
  24 kbps HLS monitor cast over HydraMesh's DCF-Audio wire, playable in any browser
- point a host-native `demod-ui-dcf` at `localhost:47000/udp` (DCF mesh)
- render **lossless** host audio with
  `docker exec <container> /work/docker/entrypoint.sh render /work/path/to/in.wav`
  → WAV lands in `./out/out.wav`

### Skip the engine (bring-your-own-privileges mode)

If you can't grant `SYS_NICE` (e.g. some sandboxed hosts), run the image with the
`quanta-only` command — `jackd`/orchestrator/`demod-rt` are skipped and only the
bridges + WASM UI serve. Good for quick UI wiring tests.

`docker run … serve` without the caps prints the exact required flags and exits
non-zero — use that hint, or switch to `quanta-only`.

## Ports

| Container | Host      | Proto | Purpose |
|-----------|-----------|-------|---------|
| 8080      | 8080      | tcp   | WASM UI + HLS monitor (`/hls/monitor.m3u8`) + `/healthz` |
| 7000      | 7000      | tcp   | `dcf-ws-bridge` (browser ⇄ UDP relay) |
| 47000     | 47000     | udp   | DCF mesh (native `demod-ui-dcf` target) |

A mounted `/out` volume is where `render` writes `out.wav`.

## Environment knobs

| Var                       | Default | Notes |
|---------------------------|---------|-------|
| `JACK_PERIOD`             | `1024`  | Larger than the 64-sample design point on purpose (cuts soft-scheduling xruns). |
| `DEMOD_DCF_PORT`          | `47000` | UDP mesh port. |
| `DEMOD_DCF_BIND`          | `0.0.0.0` in the image | Bind for the UDP bridge. Loopback-only for local `docker run` if you prefer. |
| `RT_CORE`                 | `0`     | Sched-affinity target. Orchestrator defaults to 4; container VMs usually don't have core 4 → EINVAL → exit 200. |
| `OUT`                     | `/out`  | Mounted volume for WAV renders. |
| `QSC_K`/`QSC_SNR`/`QSC_SEED` | `2048`/`45`/`0xDEC0DE` | Analyzer defaults for `render`/`analyze` when given a `.wav` input. |

## Host audio paths

HydraMesh has no raw-PCM/RTP transport; "audio over DCF" is the compressed
DCF-Audio adapter. Two host-audio paths ship:

- **HLS live monitor** — `demod-dcf-audiocast` casts the engine output over the
  DCF-Audio wire (24 kbps Opus), `dcf-ffmpeg` decodes it, and it is served as HLS at
  `http://localhost:8080/hls/monitor.m3u8` — playable in any Mac/Windows browser.
  A **compressed monitor**, not full fidelity.
- **Lossless WAV render** — full-band, offline:

```bash
# Bring your own .qsc (or .wav — analyzer runs first):
docker cp ./my-score.qsc <container>:/work/in.qsc
docker exec <container>   /work/docker/entrypoint.sh render /work/in.qsc
# →  $PWD/out/out.wav  on the host
```

(Linux hosts can also share the host JACK/PipeWire socket via the `linux-jack`
compose profile for a full-fidelity near-real-time path.)

## Licensing

The docker glue is **MPL-2.0**. The image *links* (as Nix-built binaries)
components under:
- `quanta`, `audio-stack/rt-audio`, `audio-stack/orchestrator` — GPL-3.0-only
  (dual-licensed DCSL for the quanta codec)
- `audio-stack/bridge`, `web/bridge`, `src/ipc/dm_dcf` — LGPL-3.0-only
- WASM UI + framework root — MPL-2.0

See [`LICENSING.md`](https://github.com/ALH477/DeMoD/blob/main/LICENSING.md)
in the source repo. **A distributed image must honor those licenses**
(offer-corresponding-source); this is a **dev image**, intended to be built
locally by each contributor.

## Troubleshooting

- **`docker run` exits with the "needs scheduler + memory privileges" hint** —
  add `--cap-add=SYS_NICE --cap-add=IPC_LOCK --ulimit rtprio=95 --ulimit memlock=-1`. The orchestrator hard-exits `200–204` (`Supervisor.hs`: 200 affinity, 201 sched_fifo, 202 memlock, 203 mlockall, 204 child exec) without them.
- **`jackd` / orchestrator die with `Bus error (core dumped)` on startup** — the
  container's `/dev/shm` is too small (Docker default 64 MB). Add `--shm-size=512m`
  (compose sets `shm_size: "512m"` for you). Their audio buffers + IPC regions
  live in `/dev/shm`.
- **`--rt-core 0`?** The orchestrator's default is core 4, but container VMs
  usually have ≤4 CPUs and core 4 isn't in the affinity set → EINVAL → exit 200.
  The image uses `RT_CORE=0` by default for this reason.
- **Engine reports nonzero xruns / doesn't hit the 1.33 ms budget** — that's
  expected in soft-RT; the warning at the top of this page is not a bug.
  Use a real DeMoD machine (PREEMPT_RT, `isolcpus`, SCHED_FIFO 80, `mlockall`)
  for any latency work.

## Source & issues

- **Source:** <https://github.com/ALH477/DeMoD>
- **Issues / PRs:** <https://github.com/ALH477/DeMoD/issues>
- **Container design doc:** [`docker/README.md`](https://github.com/ALH477/DeMoD/blob/main/docker/README.md) in the repo
- **Spec / codec docs:** [`quanta/docs/SPEC.md`](https://github.com/ALH477/DeMoD/blob/main/quanta/docs/SPEC.md)

This image is rebuilt from `flake.lock`-pinned nixpkgs — the `nixpkgs` revision, `quanta`, `audio-stack`, `web/bridge`, and the WASM UI artifact hashes are reproducible from the repo at the tagged commit.