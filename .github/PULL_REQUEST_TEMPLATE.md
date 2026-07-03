## What & why

<!-- What does this change, and why? Link any issue. -->

## Checklist

- [ ] Commits are signed off (`git commit -s`) — we use the Developer Certificate of Origin.
- [ ] New source files carry an `SPDX-License-Identifier` header (MPL-2.0 for the
      framework; GPL-3.0-only under `audio-stack/`; LGPL-3.0 for DCF glue).
- [ ] `make` and `make test` pass; if this touches runtime behavior, an example or the
      DCF loopback still runs clean.
- [ ] No vendored code was relicensed; no generated artifacts committed.
