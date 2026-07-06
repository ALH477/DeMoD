# Changelog

All notable changes to this project are documented here. Format follows
[Keep a Changelog](https://keepachangelog.com/); this project uses semantic-ish
versioning while pre-1.0.

## [Unreleased]

### Added
- **AR passthrough HUD** (opt-in, `make ARHUD=1`): composite the flat UI over a live
  camera/video feed as a background layer, turning any Lua app into an instrument
  overlay. New `dm.ar` binding (`open`/`config`/`status`/`close`) reads out-of-process
  RGBA frames (file / mmap / POSIX shm triple-buffer / FIFO — decode stays out of the
  UI, as with `auto/camera.lua`). Adds the `dm_fb_blit_scaled` (scale-to-fit /
  opaque-copy) and `dm_fb_warp_barrel` (lens barrel-distortion) framebuffer
  primitives. Supports mono and **side-by-side stereo** (`eyes=2`) with per-eye lens
  correction (`k1`/`k2`) for Cardboard-style viewers, plus **6DOF head tracking** via
  `dm.pose` → the `on_pose(x,y,z, qx,qy,qz,qw)` Lua callback. `examples/ar_hud.lua`
  demo + `tools/ar_testframe.sh` synthetic producer + a headless `./dev test ar` gate.
  The default build is byte-unchanged (`dm.ar`/`dm.pose` absent).
- **OpenXR present sink** (opt-in, `make XR=1`, **UNTESTED reference scaffold**): a
  `DmPresentSink` seam that routes the CPU framebuffer to an OpenXR head-locked quad
  layer (`src/ar/xr_sink.c`) instead of the SDL window, so the software UI can float
  as a panel in a headset. Compiles to a no-op stub without the OpenXR SDK (SDL
  fallback); the live path needs an SDK + OpenGL context + headset and is documented
  as needing hardware validation — see `docs/xr-sink.md`. Default/`ARHUD` builds are
  byte-unchanged (no seam without `DEMOD_XR`).
- **DeMoD Quanta codec** (`quanta/`, GPLv3-or-commercial): an analysis-to-synthesis
  audio compiler — a matching-pursuit analyzer turns a WAV into a `.qsc` score, and
  the freeze step compiles that score into a pure static Faust `.dsp` (the decoder is
  a `.dsp`). Three standalone C CLIs (`quanta-analyzer` / `-render` / `-freeze`) plus
  a Lua score-browser panel (MPL-2.0). Flake outputs `packages.quanta` and
  `apps.quanta` (`nix run .#quanta`). Verified: null test −260.7 dBFS (gate ≤ −120),
  M0 tonal LSD 1.55 dB.
- **MCP quanta tools**: `demod_quanta_compile` (WAV → score → frozen `.dsp`),
  `demod_quanta_verify` (the null + M0 tonal gates), and `demod_quanta_render`
  (score-browser panel → PNG), plus the `demod://quanta-spec` resource. The flake
  devShell gains `faust` + numpy so `cd quanta && make test` runs under `nix develop`.
- **DCF / HydraMesh remote transport** (opt-in, `make DCF=1`): run the engine on
  another machine and drive it from the UI over UDP. New `dm.dcf` binding,
  `demod-remote-bridge` sidecar, vendored LGPL-3.0 codecs, and a headless loopback
  proof. Flake outputs `demod-ui-dcf` and `demod-remote-bridge`.
- Continuous integration (GitHub Actions): builds the framework, runs the UTF-8
  tests, the DCF loopback, and a headless render-smoke of every example.
- Screenshots + an ecosystem section (ArchibaldOS / HydraMesh) in the README.
- **Quanta speech back-end (v0.3.1)**: a from-scratch Harmonic + Noise / harmonic
  minimum-phase **speech vocoder** — new C tools `quanta-speech-analyze` /
  `-render` / `-sines` (QSP container `include/qsp.h`; McAulay–Quatieri continuous
  cubic-phase synthesis; libm-free, Faust-freezable hot path) and a full Python
  research + benchmark suite under `quanta/tools/` (`qvoc`/`qcodec`/`lsf`,
  `bench_speech.py` vs **Codec2** with objective **PESQ**+MCD, LSF/predictive VQ
  training). Honest results: the vocoder **ties Codec2-2400 uncompressed** at 8 kHz
  and delivers **audibly superior wideband (16 kHz) speech** — a bandwidth Codec2/
  MELPe are structurally locked out of — while **not** matching Codec2's narrowband
  coding bit-efficiency (a deep, documented gap). MCP gains `demod_speech_bench` /
  `_code` / `_sweep`, and `demod_quanta_compile` gains a `quality` (0..10) fidelity
  dial for the noise-residual/bitrate trade. Flake `quanta` bumped 0.3.0 → 0.3.1
  (ships the three speech CLIs).

### Fixed
- `dm.viz_add_item` / `dm.control_add_item` dereferenced a boxed widget pointer as
  a raw one, crashing the `dm.viz` / `dm.control` DSLs (segfault in `make run-viz`
  and `make run-launcher`).
- Double-free at exit in the `dm.viz` / `dm.control` widget destructors (they freed
  `w->data`, which `dm_widget_destroy` already owns).

## [0.1.0] - 2026-07-03

### Added
- Initial public release: the software-rendered SDL2/Lua GUI framework, the
  `dm.viz` / `dm.control` DSLs, the unified input funnel (keyboard, mouse, serial
  encoder, gamepad, MIDI), UTF-8/CJK text via a runtime Unifont glyph blob, and the
  optional real-time audio stack (`demod-rt` engine + `demod-orchestrator`).
