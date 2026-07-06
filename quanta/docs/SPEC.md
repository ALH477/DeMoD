# DeMoD Quanta — Analysis-to-Synthesis Compiler

**Design Specification · v0.1.0-draft · 2026-07-03 · DeMoD LLC**
**Status:** DRAFT for internal review · **Codename:** `demod-quanta`

---

## 0. Abstract

DeMoD Quanta captures arbitrary audio as a sparse set of *acoustic quanta* — Gabor atoms in the sense of Gabor (1946) — plus a transient layer and a deterministic residual model, and compiles that decomposition into a pure, static Faust program. The runtime artifact contains no neural inference, no sample playback, and no dynamic allocation: it is a fixed dataflow graph with constant per-sample cost, suitable for the JH7110/U74 target under ArchibaldOS with a provable WCET. Analysis is offline and heavy; playback is deterministic and cheap. The system is split into an analyzer, a binary score format (QSC), an interactive exploration runtime inside `demod-rt`, a freeze/codegen stage, a `demod-ui` control surface, and DCF control-plane ops, all supervised by `demod-orchestrator`.

The design premise: **a lossy codec whose decoder is a Faust program.** Atom count is the rate-distortion knob.

---

## 1. Motivation & Prior Art

`sound2faust` embeds PCM verbatim as `waveform` primitives — storage, not modeling. Sinusoidal modeling (Serra & Smith, SMS) handles tonal material but not universal audio. DDSP fits harmonic-plus-noise models with ML but drags inference into the runtime. Matching pursuit over a Gabor dictionary (Mallat & Zhang 1993; MPTK, Krstulovic & Gribonval 2006) is the universal, rate-scalable middle path: greedy, ordered, gracefully truncatable, and — critically — its decoder is trivially expressible as a fixed grain-oscillator bank.

The known failure mode of pure Gabor MP (atom-hunger on broadband noise and sharp transients) is addressed with the standard hybrid split (Daudet & Torrésani 2002; Verma & Meng 1998): tonal atoms, transient atoms, fitted-noise residual. Determinism of the "stochastic" layer is preserved because the noise source is a seeded LCG, bit-exact by construction.

## 2. Goals & Non-Goals

**Goals**

| # | Goal |
|---|------|
| G1 | Universal input: any mono PCM source (44.1/48/96 kHz), resampled to the 48 kHz canonical rate |
| G2 | Bit-exact deterministic playback across builds and across x86-64 ↔ RV64 |
| G3 | Static WCET on the embedded target; ≤ 25 % of one U74 core at 48 kHz |
| G4 | Interactive exploration (audition at any atom budget K with no recompile) |
| G5 | Single-artifact export: one self-contained `.dsp`, DeMoD SKILL v2 compliant where applicable |
| G6 | Clean licensing boundaries compatible with the marketplace |

**Non-Goals (v1)**

Real-time analysis; runtime neural inference; bitrate-optimal codec competition (MP3/AAC replacement); polyphonic source separation; stereo (v1 is mono — see §15); MPEG conformance.

## 3. System Overview

```
                    ┌────────────────────────────────────────────┐
                    │            demod-orchestrator (Hs)          │
                    │   job FSM · supervision · journaling        │
                    └───┬──────────────┬──────────────┬───────────┘
                        │              │              │
   source.wav ──▶ ┌───────────┐   ┌────────────┐  ┌────────────────┐
                  │ quanta-   │──▶│  score.qsc │─▶│ freeze codegen │──▶ out.dsp ──▶ faust ▶ cc ▶ .so
                  │ analyzer  │   │  (binary)  │  │ + verify loop  │        ▲
                  └───────────┘   └─────┬──────┘  └────────────────┘        │ golden render,
                        ▲               │ shm (double-buffered)             │ LSD + null test
            DCF 0x40/41 │               ▼                                   │
                  ┌─────┴─────────────────────────┐     JACK       ┌───────┴──────┐
                  │ demod-rt :: quanta grain player│───────────────▶│  monitors /  │
                  │ (exploration mode, data-driven)│                │  JH7110 rig  │
                  └─────────────▲──────────────────┘                └──────────────┘
                                │ DCF ops 0x43–0x48 (UDP 7777, via remote bridge)
                  ┌─────────────┴──────────────────┐
                  │ demod-ui :: quanta panel (Lua)  │  logon diagram · K slider · A/B
                  └─────────────────────────────────┘
```

**Two-phase binding** is the central architectural commitment. In *exploration mode* the score is data: `demod-rt` hosts a generic deterministic grain player and the QSC score is shm-loaded, so the K slider, layer mutes, and A/B monitoring operate in real time with no recompile. In *freeze mode* the score is code: the codegen stage bakes the (possibly K-truncated) score into `rdtable`s inside a pure static `.dsp`. Same engine semantics, different binding time. Anything audible in exploration must be reproducible bit-for-bit by the frozen artifact (§7.4, §12).

Processes communicate only via files, POSIX shm, and DCF frames — the same separate-program boundary used by the rest of the platform, preserved here deliberately for both architectural and licensing reasons (§13).

## 4. Analysis Engine (`quanta-analyzer`)

Standalone C11 CLI. Input: mono PCM (via FFmpeg/soxr front-end to 48 kHz f64). Output: `score.qsc` + JSON report. No real-time constraints.

### 4.1 Hybrid three-layer decomposition

| Layer | Content | Model | Synthesis primitive |
|-------|---------|-------|---------------------|
| 0 tonal | quasi-stationary partials | long Gabor atoms (scales ≥ 1024) | windowed sinusoid |
| 1 transient | onsets, clicks, attacks | short Gabor atoms (scales ≤ 256), gated to onset neighborhoods | windowed sinusoid |
| 2 residual | broadband texture | 24-band Bark filterbank envelopes over seeded LCG noise | filtered noise |

Pipeline: onset detection (spectral flux) → matching pursuit over the full dictionary with transient atoms admissible only within ±20 ms of detected onsets (prevents MP from wasting short atoms on steady-state error) → stop per §4.6 → residual fitted per §4.5.

### 4.2 Dictionary

Gabor atoms `g(t) = (1/√‖·‖₂) · exp(−(t−u)²/2σ²) · cos(2πf(t−u)+φ)` with:

- Scales `s ∈ {2⁶ … 2¹⁴}` samples (1.3 ms – 341 ms @ 48 kHz), 9 dyadic scales, `σ = s/6`
- Time grid: hop `s/4`; frequency grid: FFT bins at `N = s`, refined post-selection by parabolic interpolation of the correlation peak; phase set analytically
- Unit L2 norm; amplitude is the pursuit coefficient
- Chirp rate field reserved in the record format, fixed 0 in v1

### 4.3 Pursuit core

Standard FFT-accelerated MP: per scale, correlations of the residual against all atoms computed via FFT; global argmax `|⟨r, g⟩|` (or masking-weighted, §4.4); subtract in time domain; repeat. Complexity `O(K · S · N log N)` with locality pruning (only re-correlate frames intersecting the last subtraction). Iteration order is fully specified (scale-major, tie-break lowest scale then lowest frequency then lowest onset) so analysis itself is deterministic and hash-stable across runs and hosts.

### 4.4 Psychoacoustic weighting (flag `--psy`)

Selection metric optionally becomes coefficient energy divided by the masked threshold at the atom's (t, f) locus, using a simplified spreading-function model (Painter & Spanias 2000). Spends the atom budget where ears notice, not where energy lives. Off by default in v1.0 so that early corpora exercise the plain-MP path; model choice is Open Question Q5.

### 4.5 Residual model

After the pursuit stops, the residual is analyzed by a 24-band Bark-spaced bandpass bank; per-band RMS envelopes at hop 256 (5.33 ms) are quantized to u16 (`g_dB = 0.25·q − 144`). Synthesis: one LCG noise source (seed from QSC header) → identical 24-band SVF bank (coefficients are compile-time constants) → per-band gains via linear-interpolated envelope tables. The layer is fully deterministic and typically costs a fixed ~10 % of the runtime budget regardless of source.

### 4.6 Stopping criteria

Pursuit halts at the first of: atom budget `K_max` (default 2048); residual energy ≤ target SNR (default 35 dB); marginal atom coefficient below salience floor (−80 dBFS). All three recorded in the report.

### 4.7 Voice assignment

Atoms are intervals `[onset, onset+dur)`. Greedy first-fit coloring in onset order is optimal for interval graphs; the chromatic number (max overlap) becomes the voice count `P`, capped at `P_max = 64`. If the cap is exceeded, the lowest-coefficient atoms in the congested span are culled and coloring re-runs (culls reported). Assignment is computed **once over the full atom set**; because pursuit rank is stored per atom, K-truncation at runtime is a pure per-atom gate (`play iff rank < K`) and never changes voice assignment. No runtime scheduler exists anywhere in the system.

## 5. QSC Score Format ("Quanta SCore")

Binary, **big-endian** (DCF convention), fixed-size records, mmap-friendly. Layout: `[header 48 B][atom records: atom_count × 32 B][residual gains: residual_frames × band_count × u16][CRC-32]`.

### 5.1 Header (48 bytes)

| Off | Size | Field | Notes |
|-----|------|-------|-------|
| 0 | 4 | magic | `"QSC1"` |
| 4 | 2 | version | `0x0001` |
| 6 | 2 | flags | bit 0: psy-weighted; bit 1: chirp present; **bit 2 (0x0004): coherent residual layer present (§5.3)** |
| 8 | 4 | sample_rate | 48000 canonical; **any rate permitted (44.1/48/88.2/96/176.4/192 kHz)** — hi-res is a rate/depth choice at the WAV boundary only, the score is rate-agnostic |
| 12 | 8 | source_len | samples, u64 |
| 20 | 4 | atom_count | K_full |
| 24 | 2 | voice_count | P |
| 26 | 1 | scale_count | 9 |
| 27 | 1 | band_count | 24 |
| 28 | 2 | residual_hop | 256 |
| 30 | 4 | residual_frames | u32 |
| 34 | 4 | noise_seed | LCG seed |
| 38 | 6 | reserved | zero |
| 44 | 4 | crc32 | over all bytes after header |

### 5.2 Atom record (32 bytes)

| Off | Size | Field | Notes |
|-----|------|-------|-------|
| 0 | 4 | rank | pursuit order, 0-based — the K-gate key |
| 4 | 4 | onset | samples (u32 spans 24.8 h @ 48 kHz) |
| 8 | 4 | dur | samples |
| 12 | 4 | freq | f32, Hz |
| 16 | 4 | amp | f32, linear coefficient (unit-norm atom) |
| 20 | 4 | phase | f32, radians |
| 24 | 4 | chirp | f32, Hz/s (0 in v1) |
| 28 | 1 | layer | 0 tonal · 1 transient · 2 reserved |
| 29 | 1 | voice | 0 … P−1 |
| 30 | 1 | scale_idx | window table selector |
| 31 | 1 | flags | reserved |

Atoms are stored **grouped by voice, onset-sorted within voice**, with a per-voice offset directory derivable from the records (voices own contiguous ranges). A 2048-atom score is 64 KiB of atoms plus residual gains — trivially shm-able and cheap enough to version-control.

### 5.3 Coherent residual layer (bit-transparent tier, flag bit 2)

The default residual (§4.5) is a **noise-substitution** model: 24 band gains driving a seeded-noise SVF bank. It reproduces the residual *spectral envelope* with a decorrelated phase realization — perceptually strong (masked on real music) but **not** waveform-transparent; measured against real 96 kHz/24-bit masters, source-SNR plateaus near 14 dB because matching pursuit saturates on the coherent partials and the remainder is broadband noise (see `docs/FIDELITY.md`).

When `--coherent` is requested the encoder additionally stores the **true post-atom residual** so the decoder nulls the *source*, not merely the reference player. Let `y0(t) = dcblock(Σ atoms)` be the atoms-only output produced by the exact renderer arithmetic (§12; the noise layer is off, master gain 1). The residual `r = source − y0` is quantized per channel and appended **after** the residual-gain block, **before** the trailing CRC (the CRC covers it):

```
[header][atoms][residual gains][coherent residual][CRC-32]
```

Coherent-residual block (present iff flag bit 2):

| Size | Field | Notes |
|------|-------|-------|
| 1 | cres_bits | quantizer precision, 8…16 |
| cc × 4 | scale[c] | per-channel dequant scale, **f32** (encode/decode dequantize with the identical value) |
| cc × source_len × 2 | samples | int16, big-endian, **channel-major** (`r[c·N + t]`); mid/side domain when stereo |

Decode adds it back after the per-channel DC blocker: `out = dcblock(atoms) + samples·scale`. Because the scale is the exact `peak/(2^{bits-1}−1)`, the null-vs-source floor is `~peak/2^{bits}` — e.g. a 16-bit residual nulls a −14 dB-peak residual to ≈ −114 dBFS, below a 24-bit source's own LSB. The layer is optional and orthogonal: a decoder that ignores flag bit 2 (or renders `--no-cres`) reproduces the lossy tier exactly, so one score carries both a ~250 kbps lossy program and a bit-transparent one. `--cbits` trades null depth for bitrate. The frozen Faust artifact emits `r` as an int16 `waveform{}` table read by the sample counter and added post-`dcb`, so **the static `.dsp` is itself bit-transparent** (nulls source ≈ −114 dBFS while still nulling the C player to −280 dBFS). This is a capability, not a compression win: the residual is high-entropy, so at bit-exact depth the coded size is FLAC-class.

## 6. Exploration Runtime (`demod-rt` module)

A new engine module, `quanta_player`, added to `demod-rt` (thereby GPLv3-or-commercial, §13).

**Data path.** Scores load into a double-buffered POSIX shm region (default name `/demod-quanta-score`, configurable); an atomic slot index performs the swap; a 10 ms equal-power crossfade covers the transition (exploration mode only — the frozen artifact has no swap path). Control parameters (`K` u32, three layer gains, master gain, A/B monitor flag) are lock-free atomics written by the DCF op handler (§8).

**Audio thread contract.** No allocation, no locks, no syscalls, no libm (§12). Per-voice state is `{atom_idx, phase}`; each voice walks its own precomputed onset-sorted sequence against the global sample counter, gating each atom on `rank < K` and layer mute. Grain output: `amp · w[(t−onset) · T_s/dur] · sinT(2π f (t−onset)/SR + φ)` where `w` is the shared Gaussian window table for `scale_idx` and `sinT` is the shared sine table — both f64, linear-interpolated, and **identical to the tables the codegen bakes into Faust** (§7.2), which is what makes the exploration/freeze null test meaningful.

**A/B monitor.** Source PCM is retained in shm alongside the score; the A/B flag hard-switches (sample-aligned) between source and model — codec-listening-test ergonomics, and the fastest way to hear what the current K is discarding.

## 7. Freeze: Faust Codegen

`quanta-freeze <score.qsc> [--k N] -o out.dsp` emits one self-contained `.dsp`:

1. Parameter tables — onset/dur/freq/amp/phase per voice-slot, packed into `rdtable`s; per-voice slot ranges as compile-time constants.
2. Voice bank — `par(v, P, qvoice(v))`; each voice advances its atom index via a `letrec` counter compared against the next onset (pure `select2` logic, branch-free).
3. Window/sine tables — the shared f64 tables from §6, emitted as `rdtable` data, one window table per scale in use.
4. Residual — inline LCG (`x ← (1103515245·x + 12345) mod 2³¹`, seeded from the header) → 24-band SVF bank with hard-coded coefficients → envelope `rdtable`s with linear interp.
5. Master — layer gain hgroup (with `si.smoo` — these are the only smoothed parameters; score-driven values must stay sample-exact), summing bus, `fi.dcblocker` on output.

**SKILL v2 compliance:** `-double -ftz 2` mandatory; `si.smoo` on continuous UI params; `fi.dcblocker` on outputs. The Padé [3,2] ADAA saturator and OU-LFO clauses are **intentionally waived** — this is a transparent resynthesis path and any coloration belongs downstream. The waiver is recorded here so the deviation is a decision, not an omission.

### 7.4 Verification loop (release gate)

Every freeze runs: (a) offline render of the `.dsp` (sndfile architecture) for the full source length; (b) **null test** against the C exploration player at the same K — pass ≤ −120 dBFS peak, stretch goal bit-exact; (c) **LSD** against the source (2048/512 Hann frames, `LSD = mean_t √(mean_f (20log₁₀(|X|+ε) − 20log₁₀(|X̂|+ε))²)`), threshold per corpus class; (d) SHA-256 of the rendered PCM recorded as the golden hash — any future rebuild that changes the hash fails CI. Toolchain (faust, gcc, flags) is Nix-pinned in the flake, so golden hashes are meaningful. `VERIFY_FAILED` is never auto-retried; it surfaces the report.

## 8. Control Plane (DCF)

DeModFrame as specified: 17-byte big-endian header (`type` u8, `seq` u32, `timestamp_µs` u64, `payload_len` u32) + payload, UDP 7777, via the existing remote bridge. Type range **0x40–0x4F reserved for Quanta**:

| Type | Op | Payload |
|------|----|---------|
| 0x40 | ANALYZE_REQ | TLV: source path+SHA-256, K_max, SNR target, flags (psy, scales mask) |
| 0x41 | PROGRESS | iter u32 · atoms u32 · residual_dB f32 · eta_ms u32 — telemetry, ≤ 30 Hz, same path as meters |
| 0x42 | SCORE_READY | score_id u32 · SHA-256 · path |
| 0x43 | LOAD | score_id → shm slot |
| 0x44 | PARAM | param_id u8 (0 = K u32 · 1–3 layer gain f32 · 4 master f32) |
| 0x45 | AB | 0 = model · 1 = source |
| 0x46 | FREEZE_REQ | score_id · K |
| 0x47 | FREEZE_DONE | dsp path · report path · LSD f32 · null_dBFS f32 |
| 0x48 | SWAP | slot u8 |
| 0x4F | ERR | code u16 · msg |

This split lets analysis run on the Framework 16 while the player sits on the JH7110 and the panel runs anywhere on the mesh.

## 9. Orchestrator Integration

One Haskell-supervised job type, journaled to disk so `SCORE_READY` survives restarts:

```
IDLE → ANALYZING → SCORE_READY → EXPLORING ⇄ (PARAM/AB/LOAD)
     → FREEZING → COMPILING → VERIFYING → DEPLOYED
                                    ↘ VERIFY_FAILED (terminal, report surfaced)
ANALYZING failure → FAILED (retryable, bounded backoff)
```

The supervisor owns the `analyze → codegen → faust → cc → dlopen/swap` pipeline; the analyzer crashing never touches the audio process.

## 10. User Interface (`demod-ui` panel)

`quanta_panel.lua`, shipped under `examples/` (MPL-2.0). Desktop layout 1280×720, root `vbox`.

**Structure.** Top transport row (`hbox`): `dm.button` Open/Analyze/Freeze, `dm.toggle` A/B, `dm.progress` + `dm.label` for job status fed by 0x41 telemetry. Center: a `dm.panel` reserving the logon-diagram viewport, drawn as a custom overlay in `on_draw()` (v0.2 promotes it to a C widget via the `DmWidgetVT` vtable + Lua registration once the rendering settles). Right rail (`vbox`): `dm.slider` for K (log-mapped 1…K_full, `on_change` → 0x44), three `dm.knob`s for layer gains (`set_format("%.1f dB")`), `dm.vu_meter(2)` on resynth out, `dm.waveform` as a residual scope. Bottom: hover inspector `dm.label` (rank · layer · f · onset · dur · amp).

**Logon diagram.** Time → x, log₂-frequency → y (32 Hz–16 kHz). Each atom renders as a Gabor cell centered at (onset+dur/2, f) with extents Δt ∝ s and Δf ∝ 1/s — equal-area on linear axes per the uncertainty product, visibly area-warped on the log-f axis (intentional; it reads as "one quantum each"). No ellipse primitive exists, so cells are drawn as three stacked passes for phosphor glow, per house style: `dm.draw.circle`-approximated fill at α≈28, a 12-segment `dm.draw.line` outline at α≈90, and a core `dm.draw.thick_line` tick at α≈200. Layer colors: tonal `dm.color.turquoise`, transient `dm.color.violet`, residual band underlay in mid-gray. Alpha additionally maps amp (−60…0 dBFS → 40…255). Atoms with `rank ≥ K` stay visible but dimmed to α≈18 — the budget's discards are always on screen. Playhead is a vertical turquoise `dm.draw.line`; scrubbing the pursuit *rank* axis (drag on the K slider while playing) lets you hear the sound assemble greedily.

**Performance.** LOD: below 1 px of Δt, atoms collapse into per-column heat accumulation; primitive budget ≤ 5 k/frame; `dm.redraw()` requested from `on_update()` only while playing, scrubbing, or telemetry is live (per the framework's redraw-on-demand contract).

**Guitar variant.** Same script, layout branch on `dm.width() ≤ 320`: paged `dm.knob` bank on the encoder (K, three layer gains, master), status label, 2-ch VU. No diagram at 320 px — the K knob plus A/B toggle is the whole instrument there.

## 11. Performance Budget (JH7110 / U74 @ 1.5 GHz, 48 kHz)

| Component | Cost model | Estimate |
|-----------|-----------|----------|
| Voice bank, P = 64 | ~20 flop/voice/sample (2 table interps + phase/env bookkeeping) | ≈ 61 MFLOPS |
| Residual bank, 24 SVF + envelopes | ~10 flop/band/sample | ≈ 12 MFLOPS |
| Total audio | | **≤ 25 % of one U74 core** (budget; measure at M5) |
| Score memory | 2048 atoms × 32 B + gains | ≈ 64–200 KiB |
| Tables | (9 windows + 1 sine) × 4096 × f64 | ≈ 320 KiB (fits shared L2) |
| Analysis (offline) | O(K·S·N log N), pruned | target < 60 s for 10 s source, K = 2048, Framework 16 |

## 12. Determinism Policy

Bit-exactness is a **specified property**, not an aspiration:

1. f64 end-to-end; Faust `-double -ftz 2`; C compiled `-fno-fast-math -ffp-contract=off` (no FMA contraction — required for x86-64 ↔ RV64 identity).
2. **No libm in any audio path.** All transcendentals via the shared f64 tables + linear interpolation (§6/§7.2); libc `sin` differs across platforms and would silently break G2.
3. Noise via the specified LCG only, seeded from the QSC header; `no.noise` is not used.
4. Fully specified iteration and summation order in analyzer, player, and generated code.
5. Nix-pinned toolchain; golden SHA-256 renders as CI regression gates (§7.4).

## 13. Licensing & IP

| Component | License | Rationale |
|-----------|---------|-----------|
| `quanta-analyzer` (standalone CLI) | GPLv3-or-commercial | Crown jewel; matches audio-stack posture. Separate-program boundary (files/shm/DCF only) keeps it license-independent of everything it talks to |
| QSC format | Published open specification, royalty-free | Ecosystem play; the spec is this document's §5 |
| `quanta_player` module | GPLv3-or-commercial | Lands inside `demod-rt`, inherits its dual license |
| `quanta_panel.lua` | MPL-2.0 | Ships in `demod-ui` examples |
| Generated `.dsp` / compiled output | Property of the score owner | Compiler-output doctrine; **AI-1:** verify the current faustlibraries exception text covers marketplace redistribution of generated code before first sale |
| QSC scores on the marketplace | DCSL asset terms | See below |

**Derivative-work exposure (flag for marketplace TOS).** A QSC score analyzed from a third-party recording is plausibly a derivative work of that recording — this is sampling with extra steps, and resynthesis quality makes the argument stronger, not weaker. Marketplace listing terms must require a rights warranty on source material, and the DMCA agent/takedown path must cover scores explicitly. **AI-2:** fold into the existing marketplace terms before QSC assets are sellable.

## 14. Milestones & Acceptance Criteria

| M | Deliverable | Acceptance |
|---|-------------|------------|
| M0 | Analyzer core: tonal-only MP, QSC writer, C reference renderer, LSD report | Deterministic (hash-stable) across runs and hosts; LSD ≤ 1.0 dB on tonal corpus (glockenspiel, sustained guitar) at K = 2048 |
| M1 | Hybrid layers: onset gating, transient atoms, residual model; `--psy` flag | Castanets + applause corpus: transient smearing absent in AB; residual SNR reported per band |
| M2 | `quanta_player` in `demod-rt`: shm load, K-gate, layer mutes, A/B | Zero underruns at P = 64 on Framework 16 **and** JH7110; null vs reference renderer ≤ −120 dBFS |
| M3 | Panel + DCF ops 0x40–0x4F + telemetry | End-to-end analyze → audition → scrub from the panel over the bridge |
| M4 | Freeze codegen + Nix-pinned verify loop | Frozen `.dsp` nulls vs exploration player ≤ −120 dBFS at matched K; golden hashes in CI |
| M5 | Embedded deploy + guitar variant | Measured core utilization ≤ 25 % on U74; encoder-paged panel at 320 px from the same Lua |

## 15. Open Questions

**Q1** Chirp atoms in v1.1 — worth the dictionary blowup, or does scale diversity cover glides well enough? **Q2** Stereo strategy: dual-mono scores, M/S, or coupled atoms with an interchannel (amp, delay) pair per record? **Q3** Damped-sinusoid record type (layer 2 reserved) for modal tails — ESPRIT fit vs. letting short Gabor atoms absorb them. **Q4** Score container compression (zstd frame around §5) for marketplace distribution vs. mmap simplicity. **Q5** Psychoacoustic model selection for `--psy` (simplified spreading vs. ISO-style Model 1). **Q6** Score watermarking/fingerprinting for marketplace provenance. **Q7** Streaming/windowed QSC for long-form sources (> u32 samples never binds, but shm size does).

## 16. References

Gabor, D. (1946). *Theory of Communication.* — acoustic quanta / logons. · Mallat, S. & Zhang, Z. (1993). *Matching Pursuits with Time-Frequency Dictionaries.* · Serra, X. & Smith, J. (1990). *Spectral Modeling Synthesis.* · Verma, T. & Meng, T. (1998). *Transient modeling synthesis.* · Daudet, L. & Torrésani, B. (2002). *Hybrid representations for audiophonic signal encoding.* · Goodwin, M. & Vetterli, M. (1999). *Matching pursuit and atomic signal models.* · Krstulovic, S. & Gribonval, R. (2006). *MPTK: Matching Pursuit made tractable.* · Ravelli, E., Richard, G. & Daudet, L. (2008). *Union of MDCT bases for audio coding.* · Painter, T. & Spanias, A. (2000). *Perceptual coding of digital audio.* · Engel, J. et al. (2020). *DDSP: Differentiable Digital Signal Processing.* · Roads, C. (2001). *Microsound.* · Faust manual & faustlibraries documentation.

---

## Appendix S. Streaming Profile & QSS Container (v0.2)

`demod-quanta` is an **asymmetric codec**: the frozen decoder is real-time by
construction, while the offline analyzer performs a greedy *global* matching
pursuit that is non-causal (largest scale = 341 ms) and iterative. The
streaming profile trades encode fidelity for a **bounded-latency causal
encode**, producing the framed **QSS** container. Decode is real-time in every
mode; a streaming-encoded QSS bridges to a byte-exact QSC and thus to the same
frozen-Faust decoder.

### S.1 Encoder — commit-horizon block matching pursuit
The signal is swept by a write head in hops of `hop` samples. A commit point
trails the head by `L = cap + active`; pursuit runs over the working set
`[comm, head − cap]`. Three properties make this behave like the offline
pursuit within a latency bound:

1. **Scale cap** (`--lat-scale cap`) bounds the largest atom and therefore the
   algorithmic latency floor at `cap` samples.
2. **Coarse-to-fine maturity.** A region is eligible for placement only once
   *all* scales ≤ `cap` have fully arrived there (onset `u` s.t. `u + cap ≤
   head`), not merely the scale being tried (`u + s ≤ head`). Without this,
   short-scale frames mature first and greedy MP tiles a sustained partial with
   dozens of short grains instead of one long atom (~20 dB less efficient per
   atom). With it, long and short scales compete on equal footing and the long
   atoms win first — matching the offline pick order.
3. **Working set** (`--active`) widens the re-pursued window before its trailing
   edge freezes. `active → whole signal` reproduces the offline pursuit exactly;
   narrower `active` lowers latency at a fidelity cost.

At end-of-stream (`head = N`) a **flush** relaxes maturity to per-scale
(`u + s ≤ head`) so the final `cap` samples, which never mature under the normal
rule, are still modeled.

**Rate control.** Offline pursues to an amplitude floor; streaming caps atoms
per hop via `--rate` (atoms/s), which sets the bitrate. Dense content at a
fixed rate degrades gracefully.

**Causal residual.** The offline global-scalar trim is not signal-stable once
made causal (it swings −0.8 to −5.1 dB with spectrum, since band-overlap
coherence depends on where the energy sits). The streaming residual instead
applies a **per-frame trim** `√(E_res_frame / gᵀCg)`, where `C` is the fixed
24×24 band-coherence matrix (`qsc_band_coherence`, `diag(C) = ρ²`) and `gᵀCg`
predicts synthesized frame energy to <1%. This is causal *and* strictly better
than the offline scalar. Residual frames freeze one commit behind the atom
stream (their env interpolates `f0 → f0+1`).

**Online voice assignment.** Committed atoms are first-fit assigned to voices
at commit time; overflow past `P_max = 64` culls the lowest-priority atom, whose
waveform is returned to the residual before that region's residual freezes, so
energy accounting stays closed.

### S.2 Latency model
- Atom stream latency floor: `cap` (85 ms @ 4096, 43 ms @ 2048, 21 ms @ 1024).
- Freeze delay behind head: `L = cap + active`.
- Residual adds one `residual_hop` (256 samples ≈ 5.3 ms) for the envelope
  interpolation frontier.
- **Presets:** `live` (cap 1024 / active 2048 / 1500 a·s⁻¹), `near`
  (2048 / 4096 / 1100 a·s⁻¹), `relaxed` (4096 / 8192 / 700 a·s⁻¹). Each preset's
  default atom rate scales down with cap: longer atoms are more efficient, so a
  lower rate keeps the 64-voice working set from saturating (over-placing dense
  long atoms otherwise culls them into the residual). More latency thus buys
  lower bitrate at comparable atom fidelity rather than degrading it.

### S.3 Fidelity/latency tradeoff (honest)
Sustained-tonal content (partials ringing ≫ `cap`) is the **worst case**: the
efficient representation needs windows longer than the latency budget, so the
commit horizon forecloses it. On the tonal corpus, pursuit residual is ≈ −28 dB
at 85 ms vs the offline −44 dB, narrowing toward offline only as `active`
approaches the ring-out time. Percussive / transient / speech-like content
(localized energy, short atoms sufficient) fares far better and is the profile's
intended use. The scale cap alone is *not* the limit (offline restricted to
`cap = 1024` still reaches −49 dB with enough atoms); the cost is committing
atoms before a sustained partial has been fully observed.

### S.4 QSS container (big-endian; DCF convention)
**Stream header (40 bytes):** `magic` (`'QSS2'` coded / `'QSS1'` legacy uncompressed)
· `sample_rate` · `source_len` · `cap` · `hop` · `active` · `band_count` ·
`residual_hop` · `noise_seed` · `flags` · `CRC-16/CCITT over the first 32 bytes`.

**Packet (one per commit hop, self-delimiting).** Plaintext framing wraps a
Rice-coded body so packets stay independently seekable/verifiable:
`sync 0xA55A` · `hop_index u32` · `flags u16` · `n_atoms u16` · `n_res u16` ·
`body_len u16` · `coded_body[body_len]` · `CRC-16/CCITT over hop_index…body`.

**Coded body (MSB-first bit stream).** Each field is a Rice block: a 5-bit
selector `k` (chosen to minimize block bits) then `n` Rice(k) codes with a
zig-zag map for signed values and an escape (48 ones · 0 · 32-bit raw) for
outliers. Blocks, in order: atom onset Δ (from the running previous onset,
carried across packets); scale index; freq q; amp q; phase q; then residual
frame-index Δ; residual band-gain Δ (from the previous frame's row, carried
across packets). Prediction state (previous onset, frame index, 24-band gain
row) lives in a `QssCoder` threaded across packets, so temporal deltas stay
small.

**Quantization (grids, spec-fixed).** freq → log grid at 2 cents
(`QSS_FREF = 20 Hz`); amp → 0.5 dB; phase → 8 bits. Onset, scale and the
residual envelope (0.25 dB `qsc_gain_q` domain) are coded losslessly. The
encoder applies **closed-loop quantization**: after quantizing an atom it adds
`unquantized − dequantized` back into the residual over the atom's support
before that region's residual freezes, so the residual absorbs the atom
quantization error and the decoder stays energy-consistent.

**Voice is not stored.** The decoder replays the encoder's deterministic
first-fit voice assignment (same `vfree` rule, same commit/onset order), so it
reconstructs identical voice numbers — and therefore the identical render
summation order — at zero bits. Atoms are dequantized to `float` (matching the
QSC bridge's storage) before synthesis.

Every packet carries an independent CRC, so a corrupt packet is dropped and the
reader re-anchors on the next `sync` word without desync. Packets map onto DCF
payloads (fragment across 17-byte DeModFrames, or one packet per HydraMesh
datagram on UDP 7777). On the tonal corpus the coded stream is ≈ 86 kbps
(near mode) vs ≈ 270 kbps uncompressed — a 3.1× reduction; a QSS→QSC bridge
(dequantized f32 atoms + coded residual) still freezes to a byte-exact Faust
decoder.

### S.5 Streaming decoder
`quanta-stream-decode` consumes QSS packet-by-packet with bounded memory
(per-voice atom queues retired past the play head; a small rolling residual-gain
record) and synthesizes sample-by-sample using the identical DSP core, table
lookups and summation order (voices 0..P−1, then the 24-band residual, then the
master DC-blocker). It is therefore **bit-exact** to `quanta-render`.

### S.6 Streaming verification gates (in `test/run.sh`)
- **A.** `stream-decode(QSS)` nulls against `render(QSC-bridge)` at ≤ −300 dBFS
  (bit-exact in practice — voice re-derivation + dequant consistency).
- **B.** QSS→QSC bridge freezes to Faust and nulls at ≤ −120 dBFS (holds with
  quantized atoms — the Faust decoder stays deterministic).
- **C.** A byte-flipped stream drops exactly the corrupted packet and re-anchors.
- **D.** `qbits`/`qss2` codec round-trips (bit-I/O, Rice + escape, coded packet).
- **E.** Coded stream ≤ 120 kbps and streaming atoms-only active-LSD within
  ~1 dB of the offline analyzer (the residual is a noise model; on pure-tone
  content it is attenuated at decode, as in the offline M0 path).

---

## Appendix C. Bitstream v1 conformance & hardening (v0.3.0)

The **QSS2** coded stream (magic `QSS2`) is **frozen as bitstream v1**. A conforming
decoder MUST reproduce the reference decode from the reference stream, byte-for-byte
(within the §12 numeric contract). The reference vectors are regenerated and checked
by `test/run.sh` **gate V**:

- **Stream:** `quanta-stream tonal.wav --lat-scale 1280 --active 2560 --rate 1200 --hop 512 --seed 0xDEC0DE`
  → SHA-256 `f647c1eb…756bfb86` (this reference build).
- **Decode:** `quanta-stream-decode` of that stream → f64 SHA-256 `688a2b98…75208ab5`.

Any change to the on-wire format or the decode path changes these hashes and fails
gate V; an intentional format change requires a version bump + re-frozen vectors.

**Hardening (gate Fz).** The packet readers (`qss_read_header`, `qss2_next_packet`)
are fuzzed (`test/fuzz.c`, ASan + UBSan) against flips, truncation, sync injection,
and `band_count` fuzzing. Malformed streams MUST degrade to dropped packets, never
crash. Normative bound: **`band_count ≤ QSC_BANDS` (24)** — a stream declaring more
is rejected by `qss_read_header` (−3) and by `qss2_next_packet` (returns 0); decoders
MUST NOT index residual state past 24 bands. (This closed a crafted-header stack
overflow found by the fuzzer.)

---

## Appendix U. Acoustic-Unit Segment Vocoder (v0.4, speech)

A concatenative speech front-end at the opposite end of the quality/bitrate spectrum
from the mastering tier — sub-MELPe bitrate by transmitting *unit indices + prosody*
instead of spectra. Four tools (`quanta-unit-{enroll,encode,render,freeze}`), two
containers, big-endian + CRC-32 in the QSC/QSS discipline.

- **Analysis** (shared, `include/qva.h`): 10 ms hop; per-frame cepstral spectral
  envelope, NCCF f0 with octave-snap/median cleanup, per-band voicing, and order-16
  LSFs (Levinson–Durbin + Chebyshev LPC↔LSF, `include/qlsf.h`).
- **`.qinv` inventory** (`quanta-unit-enroll`): segments enrolled clips at LSF-change /
  voicing boundaries (45–140 ms), resamples each to a fixed LSF trajectory, and either
  k-means-clusters (LBG, `include/qvq.h`) or unit-selects them into a baked codebook +
  per-unit voicing subpattern.
- **`.qspu` stream** (`quanta-unit-encode`): per utterance, nearest-unit id + quantized
  prosody contours (duration, log-f0, log-energy, voicing) — **≈698 bps, STOI 0.83**.
- **Two synthesis paths** (mirrors the music `render.c`-vs-analyzer split, §12):
  `qva_synth` is an FFT mixed-excitation minimum-phase vocoder (highest quality, offline
  reference; does **not** map to Faust). `qva_synth_det` (`quanta-unit-render --det`) is
  a deterministic time-domain path — piecewise-constant-per-frame continuous-phase
  harmonic bank + white-LCG(§12.3)→all-pole `1/A(z)` noise + baked per-frame gain —
  which **`quanta-unit-freeze` bakes to a static `.dsp`**. The frozen artifact nulls the
  `--det` render to **−292 dBFS** (`make unit-null`), exactly as the music `frozen.dsp`
  nulls `render.c` and not the analyzer.

The `.qinv`/`.qspu` wire layouts are defined by `include/qspu.h` (48-byte header, CRC-32);
this appendix is the behavioral reference. Frozen speech artifacts fall under §13.

---

*DeMoD LLC · demod.ltd · This document is the normative reference for `demod-quanta` v1. Changes require a version bump and a changelog entry.*
