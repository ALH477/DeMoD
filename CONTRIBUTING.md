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

- Keep the SPDX header on new source files. Use the correct license for the directory:
  `MPL-2.0` for the framework/shells, `GPL-3.0-only` under `audio-stack/` or `quanta/`,
  `LGPL-3.0-only` for DCF glue (`src/ipc/dm_dcf.c`), or `LicenseRef-PolyForm-Shield-1.0.0`
  under `apps/terminus/`.
- New third-party code must be MPL-2.0-compatible; record it in
  `THIRD_PARTY_LICENSES.md`. Don't relicense vendored code (e.g. monocypher).
- The framework is a pure software renderer — no GPU/OpenGL/Vulkan. Drawing is
  scanline-by-scanline in C; the fixed 8x16 font is ASCII 32–126 only.
- Build + test before sending: **`./dev check`** (builds + runs every test CI does). See
  [`DEVELOPING.md`](DEVELOPING.md) for the dev loop (`./dev run|shot|test|fmt`). `./dev fmt` (stylua +
  clang-format) is appreciated but advisory.

## License of contributions by layer

Contributions are inbound = outbound per layer: most of this repo is **MPL-2.0**, but
`audio-stack/` and `quanta/` are **GPLv3-only OR commercial**, `dm.dcf` glue is **LGPL-3.0**,
and `apps/terminus/` is **PolyForm Shield 1.0.0**. When contributing to a non-MPL directory,
your change is licensed under that directory's license, not MPL. See `LICENSING.md` for the
full map.

## Scope

This repo contains the **framework**, the companion-shell SDK + apps (`auto`, `dash`, `gcs`,
`rov`), the audio stack, the Quanta codec, and the **TERMINUS** flagship application layer
(`apps/terminus/`). Sibling repos (ArchibaldOS, Oligarchy, HydraMesh, DeMoD Voice) are
separate GitHub repositories — see `WHY.md` for clone guides.
