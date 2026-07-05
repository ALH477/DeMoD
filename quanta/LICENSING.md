# demod-quanta licensing (spec §13)

| component | license | rationale |
|---|---|---|
| quanta-analyzer, quanta-render, quanta-freeze | GPL-3.0-only OR LicenseRef-DeMoD-Commercial (DCSL) | dual-license funnel, matches HydraMesh posture |
| include/qsc.h + QSC wire format | open specification; header dual-licensed as above | interop without lock-in |
| ui/quanta_panel.lua | MPL-2.0 | matches demod-ui framework |
| generated frozen .dsp | property of the score owner | codegen output is data, not derivative of the generator |
| arch/, tools/, test/ | GPL-3.0-only OR DCSL | build/verification tooling |

## Notes

- **AI-1 (spec):** frozen artifacts import stdfaust.lib; verification builds link
  faustlibraries under its own license terms. No GPL propagation into the
  generated artifact via the generator itself.
- **AI-2 (spec):** a QSC score of a third-party recording is plausibly a
  derivative work of that recording. Marketplace listings of scores/frozen
  instruments require the DeMoD marketplace TOS rights warranty + DMCA
  designated-agent coverage. This tool does not change that exposure; it
  makes it legible.
- Contributions: inbound=outbound under GPL-3.0-only; commercial-side grants
  via DCSL CLA.

© 2026 DeMoD LLC
