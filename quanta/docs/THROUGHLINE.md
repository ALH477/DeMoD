# The through-line — your master, compiled to a static program

The premise of demod-quanta is that the **decoder is a file**. Not a bitstream fed to a
runtime, but the master itself compiled into a pure, static, dependency-free program. This
is the audiophile end of the system (the speech vocoder is the other end); the same
"decoder-as-`.dsp`" holds at every quality point in between.

Track B3 is the reproducible proof of that claim, end to end, on a real 96 kHz / 24-bit CC0
master (Open Goldberg Aria). Run it yourself:

```
make throughline        # the full chain + all six gates below
```

## The chain

```
master.wav ─▶ quanta-analyzer --coherent ─▶ score.qsc ─▶ quanta-freeze ─▶ master.dsp
                                                                              │
                              faust -lang c -double -a arch/player.arch ──────┘
                                        │
                                        ▼
                              gcc … player.c ─▶  ./my_master   (a standalone program)
```

Four commands turn a recording into an executable that *is* that recording:

```
bin/quanta-analyzer master.wav -o master.qsc --quality 10 --coherent
bin/quanta-freeze   master.qsc -o master.dsp --verify
faust -lang c -double -cn quanta -a arch/player.arch master.dsp -o player.c
gcc -O2 -std=c11 -ffp-contract=off -fno-fast-math -fwrapv -Iinclude player.c -o my_master -lm
```

The frozen `.dsp` bakes its own length and rate (`declare samples` / `declare samplerate`),
so `my_master` is fully self-contained — it knows how long it is and how fast to play.

## Proven (gate-backed, x86-64) — `make throughline`

Every figure below is asserted by a gate on the real 96 k/24 master, not claimed:

| # | property | result | threshold |
|---|----------|--------|-----------|
| **T1** | frozen `.dsp` nulls the C reference player (determinism) | **−280.6 dBFS** | ≤ −120 |
| **T2** | frozen `--coherent` `.dsp` nulls the **source** (bit-transparent) | **−113.6 dBFS** | ≤ −100 |
| **T3** | generated `computequanta()` audio loop is **allocation-free** | 0 alloc calls (in a ~2400-line inner loop) | 0 |
| **T4** | generated `computequanta()` audio loop is **libm-free** | 0 transcendental calls per sample | 0 |
| **T5** | the whole chain is **byte-reproducible** | identical SHA-256 across two full runs | equal |
| **T6** | the standalone **player** == the offline harness | byte-for-byte identical | equal |

What each means, plainly:
- **T1/T2** — the program reproduces the master *exactly*: it nulls the C reference player to
  −280 dBFS (pure determinism), and with the coherent tier it nulls the *original recording*
  to −114 dBFS, below a 16-bit source's own noise floor. Two independent implementations
  (the C player and the Faust-generated C) agree.
- **T3/T4** — the per-sample audio path allocates no memory and calls no `libm`: transcendentals
  come only from two 4096-entry tables baked into the `.dsp` as literals; the inner loop is
  table reads, adds/multiplies, and an integer LCG. Fixed dataflow, **constant per-sample cost**.
- **T5/T6** — same input → same bytes, every time, on this host; and the real-time player path
  is bit-identical to the offline renderer.

The player links **only `libc` and `libm`** — no audio library, no codec runtime, no dynamic
allocation in the loop.

## Hearing it

```
bash tools/quanta-play.sh master.dsp          # stream to the first available sink
bash tools/quanta-play.sh master.dsp 10       # first 10 seconds
```

`quanta-play` compiles the frozen master with `arch/player.arch` and streams f32 in real time
to `pw-play` / `aplay` / `ffplay` — the player has zero audio-library dependencies, so the
system sink does the device I/O. For a player that owns the device directly, build with ALSA:

```
faust -lang c -double -cn quanta -a arch/player.arch master.dsp -o player.c
gcc -O2 -std=gnu11 -DQUANTA_ALSA -Iinclude player.c -o my_master -lm -lasound   # -std=gnu11 for ALSA
./my_master --alsa
```

## Honest boundaries — what is *not* claimed

The value here is **decoder portability and determinism**, stated precisely so it holds up:

- **Not a compression win.** The `--coherent` residual is high-entropy; at bit-exact depth the
  coded size is FLAC-class. The win is *one scalable file* (lossy ~250 kbps ↔ bit-exact) whose
  decoder is a static `.dsp` at every point — not "smaller than FLAC". (See `docs/FIDELITY.md`.)
- **"Zero-jitter / constant per-sample cost" is true by construction, not benchmarked on
  silicon.** The generated graph is a fixed dataflow with no runtime scheduler (T3/T4 show the
  loop is allocation- and libm-free), so cost per sample is constant *by structure*. That is a
  different, weaker claim than a *measured* WCET or latency bound on specific hardware.
- **The following remain aspirational and are flagged as such in the spec, not demonstrated
  here:** deployment on the JH7110 / U74 target, a *provable* WCET, the "≤ 25 % of one U74 core"
  budget (SPEC §11: "budget; measure at M5"), x86-64 ↔ RV64 bit-identity (the RV64 side has never
  been built or run), and ArchibaldOS integration. All gates in this document ran on x86-64.

## Licensing

The generated `.dsp` (and anything compiled from it) is **property of the score owner** —
codegen output is data, not a derivative of the compiler (SPEC §13, `LICENSING.md`). Note the
derivative-work exposure for scores analyzed from third-party recordings (SPEC §13).
