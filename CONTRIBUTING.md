# Contributing to DeMoD UI

Thanks for hacking on the framework. It's meant to be built on and improved.

## License of contributions (inbound = outbound)

By submitting a contribution you agree it is licensed under the **Mozilla Public
License, v. 2.0** — the same license as the project. No copyright assignment and no CLA;
you keep your copyright. We just need the right to ship your change under the MPL.

## Developer Certificate of Origin (DCO)

Sign off every commit to certify you wrote the change (or have the right to submit it)
under the project's license — see <https://developercertificate.org>:

```
git commit -s
```

This adds a `Signed-off-by: Your Name <you@example.com>` line. Commits without a sign-off
won't be merged.

## Practicalities

- Keep the SPDX header (`SPDX-License-Identifier: MPL-2.0`) on new source files.
- New third-party code must be MPL-2.0-compatible; record it in
  `THIRD_PARTY_LICENSES.md`. Don't relicense vendored code (e.g. monocypher).
- The framework is a pure software renderer — no GPU/OpenGL/Vulkan. Drawing is
  scanline-by-scanline in C; the fixed 8x16 font is ASCII 32–126 only.
- Build + test before sending: **`./dev check`** (builds + runs every test CI does). See
  [`DEVELOPING.md`](DEVELOPING.md) for the dev loop (`./dev run|shot|test|fmt`). `./dev fmt` (stylua +
  clang-format) is appreciated but advisory.

## Scope

This repo is the **framework** only. The DeMoD apps, patch catalog, and marketplace are
separate and not part of this project.
