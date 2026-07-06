# demod-quanta v0.1.0

Analysis-to-synthesis compiler: decompose audio into **Gabor acoustic quanta**
(Mallat–Zhang matching pursuit) plus a transient layer and a deterministic
noise residual, then **freeze the score into a pure static Faust program** —
a lossy codec whose decoder is a Faust program.

Part of the DeMoD instrument platform. Spec: `docs/SPEC.md`.

```
                       offline (global MP, best fidelity)
WAV ──► quanta-analyzer ──► score.qsc ──► quanta-render     (reference player)
                                    └───► quanta-freeze ──► frozen.dsp ──► faust

                       streaming (bounded-latency causal encode; Appendix S)
WAV ──► quanta-stream ──► stream.qss ──► quanta-stream-decode   (bit-exact to render)
                    └──► --qsc bridge.qsc ──► quanta-freeze ──► faust
```

The codec is **asymmetric**: decode is real-time in every mode, encode is the
expensive side. `quanta-analyzer` is the archival/marketplace encoder;
`quanta-stream` is a bounded-latency live/monitoring encoder producing the
framed **QSS** container (spec Appendix S). A QSS stream decodes incrementally
with bounded memory and bridges to a byte-exact QSC.

## Build

```
make            # gcc, -std=c11; bin/quanta-{analyzer,render,freeze,stream,stream-decode}
make test       # full verification loop incl. streaming gates (needs faust + python3-numpy)
nix develop     # devshell with gcc, faust, python3+numpy   [not exercised in CI yet]
```

## Usage

```
bin/quanta-analyzer in.wav -o score.qsc [--quality 0..10 | --k 2048 --snr 45] [--seed 0xDEC0DE] [--stereo]
bin/quanta-render   score.qsc [--k N] [--g0 G --g1 G --g2 G] [--wav out.wav] [--raw out.f64]
bin/quanta-freeze   score.qsc -o frozen.dsp [--k N] [--verify] [--lua ui/score.lua]
faust -lang c -double -cn quanta -a arch/minimal_c.arch frozen.dsp -o gen.c
./demod-ui ui/quanta_panel.lua        # score browser (demod-ui framework)

# streaming profile (Appendix S)
bin/quanta-stream        in.wav -o out.qss [--mode live|near|relaxed] [--qsc bridge.qsc]
                         [--lat-scale N] [--active N] [--rate atoms/s] [--hop N]
bin/quanta-stream-decode out.qss [--raw out.f64] [--wav out.wav]
```

### Fidelity vs bitrate — tuning the noise residual

Quanta models tonal content as Gabor atoms and stands in for everything else
(high-frequency air, breath, bow/room noise) with a **24-band noise-substitution
residual** — a light, envelope-matched noise layer, mostly above ~6 kHz where the
atoms don't reach. It is calibrated to the *true* residual level (not a gain error);
it is the price of the codec's compactness. To trade bits for a quieter residual:

- **`--quality 0..10`** (offline analyzer) — the one dial. Higher = more atoms and a
  higher pursuit-stop SNR, so more of the signal is captured tonally and the residual
  noise drops, at more bits. `0` favours bitrate; `10` favours fidelity.
- **`--k` / `--snr`** — the manual pair behind the dial (atom budget / pursuit-stop
  SNR in dB) when you want direct control. Ignored when `--quality` is set.
- **streaming** — the `--mode live|near|relaxed` latency presets pick cap-appropriate
  atom rates (see below); more latency buys a lower bitrate at comparable fidelity.

These are exposed on the CLI above and via the `demod_quanta_compile` MCP tool
(`quality` / `k` / `snr` params).

Latency presets carry cap-appropriate default atom rates (larger cap → longer,
more efficient atoms → lower rate, so voice pressure stays bounded): `live`
64 ms (cap 1024 / active 2048 / 1500 a/s / ≈98 kbps), `near` 128 ms
(2048 / 4096 / 1100 a/s / ≈83 kbps), `relaxed` 256 ms (4096 / 8192 / 700 a/s /
≈64 kbps). More latency buys lower bitrate at comparable fidelity. Sustained
tonal is the worst case for the atom pursuit (see Appendix S.3); percussive and
speech-like content fare far better.

The QSS stream is entropy-coded (Rice-coded quantized atoms + delta-coded
residual envelope): ≈ 3.1× smaller than uncompressed. Atoms are quantized to a
2-cent / 0.5 dB / 8-bit-phase grid with closed-loop error feedback into the
residual; the streaming atoms reconstruct to within ~1.6 dB active-LSD of the
offline analyzer. Voice labels are not stored — the decoder replays the
encoder's deterministic first-fit assignment, preserving bit-exact synthesis at
zero bits.

`--verify` emits unity constants instead of UI sliders so golden renders are
deterministic (si.smoo ramps from 0 at init and would break the null test).
Default emission carries the four SKILL-v2-smoothed dB sliders
(tonal / transient / residual / master).

## Verified results (this build, in-tree corpora)

Null test — frozen Faust artifact vs C reference player, identical inputs:

| corpus  | atoms | voices | peak diff | rms diff |
|---------|------:|-------:|----------:|---------:|
| hybrid  |  400  |  44–45 | −260.7 dBFS | −281.6 dBFS |
| tonal   | 1190  |  64    | −253.6 dBFS | −275.3 dBFS |

Gate is ≤ −120 dBFS (spec §7.4): **pass with ~130 dB margin**. Renders are not
literally bit-exact: Faust's signal-level normalization reorders floating-point
expressions relative to the reference C; the discrepancy is confined to f64
rounding (~1e-13 absolute). Locking bit-exactness would require constraining
Faust's simplifier and is deferred (spec §12 note).

Fidelity — tonal corpus (M0 acceptance config: atoms only, `--g2 0`),
K=2048 budget, P=64:

* pursuit residual **−43.61 dB** re source; voice-culled 858 atoms
  (**−39.69 dB**) returned to the residual layer
* time-domain SNR **+38.25 dB** (matches −43.61 ⊕ −39.69 exactly — energy
  accounting is closed)
* active-frame LSD **1.55 dB** vs the 1.0 dB spec target — **not met in v0.1**.
  Root cause: the P=64 voice cap saturates on long stacked decay tails, and the
  culled refinement content is absent from the atoms-only measurement by
  construction. The shipped full engine absorbs culls into the residual layer
  (full-engine SNR +35.05 dB). CI regression gate is set at 1.6 dB.
  Paths to the 1.0 target: chirped atoms (chirp field is reserved in QSC),
  per-span salience-aware culling, or a P budget revisit — all v0.2 scope.

Fidelity metrics are DC-blocker-compensated (the output blocker is part of the
artifact's output stage, not modeling error — it costs ~14 dB of raw
phase-sensitive SNR at mid frequencies if uncompensated) and use a −80 dB
frame-peak-relative spectral floor (absolute floors let empty bins of
synthetic sources dominate LSD).

## Determinism contract (spec §12)

The audio path (render + frozen artifact) is libm-free: transcendentals via
shared 4096-entry f64 window/sine tables (linear interp; sine wraps, window
clamps), emitted into the .dsp as `%.17g` literals byte-identical to the C
tables. Noise is the seeded LCG `s' = (s·1103515245 + 12345 + seed) & 0x7FFFFFFF`,
`s₀ = 0` — the seed folds into the increment (deviation from the classic
form, chosen so the Faust one-delay feedback and the C loop see identical
sequences with zero-initialized state). The residual bank is a 24-band
unity-peak TPT SVF (`bp = 0.25·v1` — the raw v1 tap has gain Q; see below).
Compile flags both sides: `-ffp-contract=off -fno-fast-math -fwrapv`, Faust
`-double`. Fixed summation order: voices 0..P−1, bands 0..23, left-associated.

**Field note (the +16.8 dB bug):** v0.0 measured band envelopes through the
raw SVF `v1` tap, whose passband gain is Q (=4), not unity. Because stored
gains are env/ρ — invariant to any per-band linear gain — the calibration
could not catch it: analysis measured Q× the true content and synthesis
faithfully reproduced the amplified value, +12 dB, plus ~+1.8 dB band-overlap
double-counting and ~+3 dB coherent same-noise summation. Fix: unity-peak
normalization plus a closed loop — the analyzer synthesizes the layer exactly
as the renderer will and trims all gains so layer RMS equals true residual
RMS (trim is reported per file, typically −2..−5 dB).

## Layout

```
include/qsc.h      QSC format + shared deterministic DSP core (normative)
src/analyzer.c     matching pursuit, onsets, voice assignment, residual model
src/render.c       reference player (normative audio path)
src/freeze.c       Faust codegen (+ --lua score sidecar)
arch/, test/       offline faust harness + verification loop
tools/             corpus generators + metrics
ui/quanta_panel.lua  demod-ui logon-diagram panel (DCF ops stubbed)
docs/SPEC.md       full specification
```

## Licensing

Analyzer/render/freeze: **GPL-3.0-only OR DeMoD Commercial** (DCSL).
QSC format: open specification. Panel: **MPL-2.0**. Generated `.dsp` output:
property of the score owner. Full table + marketplace notes: `LICENSING.md`.

© 2026 DeMoD LLC · DEMOD.LTD
