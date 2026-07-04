# Changelog

All notable changes to this project are documented here. Format follows
[Keep a Changelog](https://keepachangelog.com/); this project uses semantic-ish
versioning while pre-1.0.

## [Unreleased]

### Added
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
