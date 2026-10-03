## What & why

<!-- What does this change, and why? Link any issue. -->

## Checklist

- [ ] I have read `CONTRIBUTING.md`: DeMoD LLC holds the copyright, and pull requests from
      outside contributors are not merged until its contributor licence agreement is published.
- [ ] Commits are signed off (`git commit -s`) — we use the Developer Certificate of Origin.
- [ ] New source files carry an `SPDX-License-Identifier` header (MPL-2.0 for the
      framework; `GPL-3.0-only` or `GPL-3.0-only OR LicenseRef-DeMoD-Commercial` under
      `audio-stack/` or `quanta/`; LGPL-3.0-only for DCF glue;
      `LicenseRef-PolyForm-Shield-1.0.0` under `apps/terminus/`).
- [ ] `make` and `make test` pass; if this touches runtime behavior, an example or the
      DCF loopback still runs clean.
- [ ] No vendored code was relicensed; no generated artifacts committed.
