# Metal Forge — repair record (RESOLVED)

All 32 Metal Forge effects now compile, are finite at 48k/192k, and are in
`index.lua`. The 21 that originally failed (see git history of this file) were
repaired 2026-06-14; descriptors synced to the compiled bus with
`tools/sync_params.py`. Re-audit any time with:

```
nix shell nixpkgs#faust --command python3 tools/sync_params.py --check demod-mf-*
```

## Bug classes fixed (recurring across the pack)
- **`select3` used as `select2`** (boolean selector, 2 values) — the 3rd value
  became a phantom input; cascaded over par() banks → 100+ phantom inputs
  (cabinetforge, formantmorph). Author's branch order already matched select2.
- **`select2`/`select3` with circuit branches** (`select2(s, _, sat)`) instead of
  selecting between processed signals (chainmaster).
- **Malformed feedback** `(x+_*fbk) : delay : sat ~ _` / `delay(...,sig) ~ fb` —
  the `~` (tightest) binds wrong; rewrite `x : (+ : delay : sat) ~ *(fb)`
  (multitapmaze, razorflange, tempoecho, pitchdemon harmoniser).
- **`0.0 : (_ ~ step)`** seeding a 0-input OU/random generator (pulsegate,
  brokentape, ghostchorus, vectorphase, razorflange) and `_,_:max` S&H.
- **Reinvented-and-broken granular** (`with { x = x; }` tell) → use
  `ef.transpose` / a real windowed `de.fdelay` read (pitchdemon, freezeburst).
- **Gain-computer sign/branch bugs**: swapped soft-knee `select2` + missing minus
  (fullmetaljacket compressor boosted quiet +95 dB); `*(max(1e-30))` /
  `*(*(1-a))` malformed detectors (silentstrike, gateexpand); broken point-free
  biquad/limiter (chaossaw `resonlp` gain-arg, bricklimit/transientsculpt).
- **Duplicate `process`** (a broken draft + a working rewrite) — spincab,
  ironspeaker, voidroom.
- **Faust ≠ C/Haskell**: no `x => ...` lambda (use `\(x).()`), no `chain $ x`
  (pipe `x :`), `,` binds tighter than `:` (parenthesise voice chains).
- **`si.lag_ud`/`onePoleSwitching` want pole coeffs**, not seconds → `ba.tau2pole`.
- **zita T60 via `si.smoo`** ramps from 0 → div-by-zero NaN; floor `: max(0.05)`.

Harness note: `tools/harness.cpp` now `static`-allocates the dsp (big delay/reverb
structs overflow the stack).
