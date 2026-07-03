# DeMoD audio stack — orchestrator + rt engine

The real-time audio backend that the DeMoD UI framework can drive. Two programs:

- **`rt-audio/`** — **demod-rt**, a deterministic C real-time audio engine (JACK
  client). Loads Faust-compiled `.so` effects at runtime, owns the shared-memory
  param/meter buses, and runs a bounded audio callback. CMake target `demod-rt`.
- **`orchestrator/`** — **demod-orchestrator**, a Haskell control daemon. It forks
  and supervises `demod-rt` (real `SCHED_FIFO`/`mlock`), speaks a JSON-lines control
  socket (`/run/demod/control.sock`), and reads the param bus. Cabal package
  `demod-orchestrator`.
- **`ipc/`** — the shared-memory contract shared by both (and mirrored, under MPL, by
  the framework in `include/demod/`).
- **`scripts/`** — the optional device bridge.

These are **separate programs** from the UI framework: they communicate only over a
Unix socket and shared memory, with no build dependency in either direction. A UI
(this framework or any other) is optional — the stack runs headless.

## License

This directory is **dual-licensed: GPLv3-only OR commercial** — see `LICENSE` (the
"DEMOD DUAL LICENSE") and the repository-root `LICENSING.md`. This is a different
license from the MPL-2.0 framework at the repository root; each part keeps its own.

## Build

```bash
# engine (needs JACK)
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release && cmake --build build
./build/demod-rt --help

# orchestrator (Haskell)
cd orchestrator && cabal build     # or, from the repo root: nix build .#demod-orchestrator

# or via the repo-root flake:
nix build .#demod-rt .#demod-orchestrator
```

The default build does **not** ship any Faust `.dsp` effect sources (those are a
separate, separately-licensed corpus); `demod-rt` loads user-provided compiled `.so`
effects at runtime via `--faust-slot N path.so`. See `ARCHITECTURE.md` for the full
control-socket + shared-memory contract.
