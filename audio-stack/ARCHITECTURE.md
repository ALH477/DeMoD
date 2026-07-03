# DeMoD Architecture

> Technical design document for the DeMoD deterministic audio platform.
> Last updated: April 2026.

## Design Constraints

| Constraint | Value (x86 primary) | Value (RISC-V variant) | Source |
|-----------|---------------------|------------------------|--------|
| Audio callback budget | 1.33ms (64 samples @ 48kHz) | same | Whiteboard |
| Target CPU | Quad-core x86 with HT (8 logical cores) | StarFive JH7110 — quad U74-MC @ 1.5 GHz, no SMT (4 logical cores), on the DeepComputing Framework 13 RV mainboard | Whiteboard + JH7110 datasheet |
| Target RAM | < 1 GB | 8 GB on Framework 13 RV; same deterministic-memory posture (no swap, sysctl headroom) | Whiteboard |
| Target OS | NixOS + a PREEMPT_RT kernel | NixOS + mainline `linuxPackages_latest` (PREEMPT\_RT merged upstream ≥ 6.12; CachyBORE is x86-only) | Whiteboard |
| Scheduling jitter | < 60μs worst case | Target parity; JH7110 baseline not yet measured on hardware | Feasibility report |
| IPC overhead | < 500ns per callback | Architecture-neutral; same SPSC + triple buffer primitives | Feasibility report |
| GHC GC worst case | 1–5ms (non-moving GC, < 10MB heap) | same (cross-compiled via `pkgsCross.riscv64.haskell.packages.ghc984` with bundled libffi and LLVM backend) | Feasibility report |

## Core Layout

### x86 (quad-core + HT, `nosmt` on)

```
Physical Core 0 (logical 0,1) — System / Kernel / IRQs
Physical Core 1 (logical 2,3) — Haskell Orchestrator (taskset -c 2,3)
Physical Core 2 (logical 4,5) — ISOLATED: RT Audio (SCHED_FIFO 80) + Compositor
Physical Core 3 (logical 6,7) — ISOLATED: HydraMesh / DCF / Spare RT
```

With `nosmt` (recommended): 4 cores, system on 0-1, Haskell on 0-1, RT on 2, spare on 3.

### RISC-V JH7110 (4 U74 cores, no SMT)

```
Core 0 — System / Kernel / IRQs / Orchestrator housekeeping
Core 1 — Haskell Orchestrator (taskset -c 0,1)
Core 2 — ISOLATED: RT Audio (SCHED_FIFO 80)
Core 3 — ISOLATED: UI / spare RT
```

The JH7110 has no SMT to disable, so `nosmt` is omitted. The `services.demod.orchestratorCpus` option drives the housekeeping CPU set (`"0,1"` on JH7110 vs `"0,1"` on the x86 8-logical-core layout — same numeric set, different intent).

### Kernel parameters

Common (both targets):
```
isolcpus=managed_irq,domain,2-3  nohz_full=2-3  rcu_nocbs=2-3
rcu_nocb_poll  irqaffinity=0,1  kthread_cpus=0,1  nmi_watchdog=0
nosoftlockup  skew_tick=1  threadirqs
```

x86-only (stripped on RISC-V):
```
nosmt  tsc=reliable  clocksource=tsc
intel_idle.max_cstate=1  processor.max_cstate=1  mitigations=off
```

## IPC Design

All communication between Haskell and C is via POSIX shared memory (`/dev/shm`).
No syscalls, no mutexes, no pipes in the hot path. Four named regions:

### Triple Buffer (`/demod-params`)

CAS-based ownership tracking. A single `_Atomic uint32_t` packs writer, middle,
and reader indices (2 bits each) plus a dirty flag. Writer and reader each CAS
to swap their buffer with the middle buffer.

```
State word: [writer:2][middle:2][reader:2][dirty:1][unused:25]

Writer publishes:  CAS(state, old, pack(middle, writer, reader, dirty=true))
Reader swaps:      CAS(state, old, pack(writer, reader, middle, dirty=false))
```

Each buffer holds a 256-byte `DemodParamSnapshot` containing pitch, BPM,
FX params (16 slots), bypass mask, BT codec state, SDR state, and timestamp.

### SPSC Ring Buffers (`/demod-audio-cmd`, `/demod-audio-evt`)

Rigtorp/Lamport pattern with cached-index optimization. Each side caches
the other's index locally, touching the atomic only when the cache says
full/empty. This gives 20× throughput and 22× fewer L1 store misses
compared to naive SPSC.

```c
typedef struct {
    alignas(64) _Atomic uint64_t write_idx;    // Producer cache line
    uint64_t read_idx_cached;
    alignas(64) _Atomic uint64_t read_idx;     // Consumer cache line
    uint64_t write_idx_cached;
    alignas(64) uint64_t capacity, mask;       // Immutable
    alignas(64) float data[];                  // Power-of-2 sized
} DemodSpsc;
```

On x86 TSO, acquire/release compile to plain MOV — zero fence cost.

### Command Protocol

Commands are float sequences on the SPSC command ring. First float = command type.

| Command | Code | Size | Args |
|---------|------|------|------|
| FX Bypass | 3.0 | 3 | slot, on/off |
| FX Param | 4.0 | 4 | slot, param_idx, value |
| Set BPM | 10.0 | 2 | bpm |
| Set Gain | 11.0 | 2 | gain_linear |
| Ping | 90.0 | 1 | — |
| Shutdown | 99.0 | 1 | — |

## RT Audio Callback

The callback runs on an isolated core at SCHED_FIFO 80 with `mlockall`.
Every code path is branchless and allocation-free.

```
demod_rt_process(64 frames):
  1. clock_gettime                           ~20ns
  2. Process commands (max 8, SPSC pop)      ~400ns worst
  3. Triple buffer read_copy (if new seq)    ~50ns
  4. Get JACK buffers                        ~10ns
  5. Audio tap: mono sum → SPSC push         ~50ns
  6. FX chain: Faust compute() per slot      ~800μs budget
  7. Master: Padé tanh + DC block + smoo     ~50μs
  8. Heartbeat: atomic store timestamp       ~5ns
  Total non-DSP overhead:                    ~76μs (5.7%)
  Available for DSP:                         ~1,257μs (94.3%)
```

## Faust Integration

Effects are compiled to `.so` shared libraries via `faust → C++ → cc -shared`.
The RT process loads them with `dlopen` and calls `computeDsp()` each callback.

All effects use `demod_skill.lib` which defines:
- `pade_tanh(x)` — Padé [3/3] with coefficients matching the C implementation
- `dc_blocker` — `y[n] = x[n] - x[n-1] + 0.995 * y[n-1]`
- `smoo(tau)` — one-pole exponential smoother via `si.smooth`
- `ou_lfo(theta, mu, sigma, seed)` — Ornstein-Uhlenbeck mean-reverting LFO
- `allpass(dt, g)`, `fbcomb(dt, fb, damp)` — reverb building blocks
- `wet_dry(mix, dry, wet)` — standard wet/dry crossfade

## Haskell Orchestrator

Runs with: `+RTS -N2 -qg -qb -qm -I0 -A512k --nonmoving-gc -C0 -V0 -RTS`

| Flag | Purpose |
|------|---------|
| `-N2` | Two capabilities, one per core |
| `-qg` | Disable parallel GC (avoids ~1ms sync cost) |
| `-qb -qm` | Disable load balancing and migration (cache locality) |
| `-I0` | Disable idle GC (no surprise collections) |
| `-A512k` | Small nursery (fits L2, fast Gen 0: 100–500μs) |
| `--nonmoving-gc` | Concurrent old-gen collection (no stop-the-world) |
| `-C0 -V0` | Disable context switch timer and RTS interval timer |

### Green Threads

```
Orchestrator process
├── Ulation Engine    — audio tap → YIN → pitch TVar
├── OSC Router        — polls all TVars → triple buffer publish (100Hz)
├── Status Reporter   — logs health every 5s
└── Supervisor        — manages child processes
    ├── demod-rt      — core 4, FIFO 80, mlockall, infinite restarts
    ├── demod-ui      — core 5, normal, 10 max restarts
    ├── demod-lyrics   — any core, normal, 5 max restarts
    └── demod-hydramesh — core 6, normal, 3 max restarts
```

### Supervision Strategy

Each child gets independent exponential backoff: 100ms → 200ms → 400ms → ... → cap.
Backoff resets to base if the child survives > 10 seconds (was healthy).
Shutdown: SIGTERM → configurable timeout → SIGKILL → reap zombie.

## Ulation Engine

YIN pitch detection (de Cheveigné & Kawahara, 2002) running in Haskell:

1. **Difference function**: `d(τ) = Σ(x[n] - x[n+τ])²`
2. **CMND**: `d'(τ) = d(τ) * τ / Σ d(j)` for `j=1..τ`
3. **Absolute threshold**: first τ where `d'(τ) < 0.15`
4. **Parabolic interpolation**: sub-sample accuracy
5. **Frequency**: `f = 48000 / τ_refined`

Window: 2048 samples. Hop: 64 samples (one per callback). Range: 75–1400 Hz.
Detection takes ~200μs on x86. GC pauses cause at most 5ms staleness (inaudible).

## Faust effects

`demod-rt` loads Faust-compiled effects at runtime as shared objects (`--faust-slot N
path.so`). Effects are compiled with `faust -lang c`, producing a struct plus pure
functions; parameters are discovered via UIGlue callbacks that return `FAUSTFLOAT*` zone
pointers into the DSP struct, which the engine writes directly (no message passing, no
lock, no allocation). The `.dsp` effect corpus itself is separately licensed and ships
outside this repository.

## Testing

38 C tests across 6 test suites, all compiled with maximum strict warnings:

| Suite | Tests | Validates |
|-------|-------|-----------|
| SPSC Ring Buffer | 8 | Init, push/pop, wrap, full/empty, 1M threaded stress |
| Triple Buffer | 6 | Init, write/read, multi-write, no-new-data, threaded torn-read |
| Shared Memory | 4 | Create/open, full IPC, cross-process, heartbeat |
| FFI Helpers | 8 | All 30 FFI functions, 1000-cycle stress |
| Audio Tap | 5 | Sine integrity, mono mix, 48k throughput, full audible range |
| Commands | 7 | Bypass, param, BPM, 100-seq, ping, shutdown, interleaved |

Plus 11 Haskell tests (FFI round-trip + YIN pitch detection + harmonics + silence).
