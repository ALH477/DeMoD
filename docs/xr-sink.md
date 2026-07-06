<!-- SPDX-License-Identifier: MPL-2.0 -->
# OpenXR present sink (`XR=1`) — **UNTESTED reference scaffold**

> **Status: not validated on hardware.** `src/ar/xr_sink.c` is a structurally
> complete but **untested** reference. Its live OpenXR path has never run against
> a real runtime or headset in-tree. Treat it as a starting point that **must be
> completed and hardware-tested** before any use — do not ship it as-is. Without
> the OpenXR SDK it compiles to a harmless no-op stub, so `make XR=1` is safe to
> build; only the *live* path is unverified.

## What it is

DeMoD UI renders into one CPU `DmFramebuffer` (ARGB8888). Every output — the SDL
window, the PPM screenshot, the WASM canvas — is a consumer of that buffer. The
**present-sink seam** lets you swap the consumer:

```c
/* include/demod/app.h — only present under -DDEMOD_XR */
typedef struct DmPresentSink {
    void *ctx;
    void (*present)(void *ctx, const DmFramebuffer *fb);
    void (*destroy)(void *ctx);
} DmPresentSink;
```

When `app->present_sink` is set, `dm_app_frame` calls `present(ctx, app->fb)`
instead of the SDL `LockTexture → RenderCopy → RenderPresent` block. The OpenXR
sink uploads the pixels to an OpenGL swapchain texture once per frame and submits
them as a **head-locked quad layer** — the software UI floats as a ~1 m panel in
front of the viewer, with no GPU render path in the framework itself.

The seam and sink are behind `DEMOD_XR` so the **default and `ARHUD=1` builds are
byte-unchanged** (no seam, no XR code).

## Build

```bash
# Stub build — no SDK required; dm_xr_sink_create() returns NULL → SDL fallback.
make XR=1

# Live build — point DEMOD_OPENXR_SDK at an OpenXR SDK (out-of-tree, gitignored).
make XR=1 DEMOD_OPENXR_SDK=/opt/openxr-sdk
#   adds -I$SDK/include and links -lopenxr_loader -lGL -lX11.

# CMake equivalent:
cmake -DDEMOD_XR=ON -DOPENXR_SDK=/opt/openxr-sdk ..
```

Activate at runtime:

```bash
DEMOD_XR=1 ./demod-ui examples/hello.lua
```

If the runtime/headset (or, in the stub build, the SDK) is absent,
`dm_xr_sink_create` returns `NULL` and the app transparently keeps the SDL
window.

## Integration requirements (why it needs work)

1. **OpenGL context.** The sink uses the OpenGL graphics binding
   (`XrGraphicsBindingOpenGLXlibKHR`) and reads the *current* GLX context via
   `glXGetCurrentContext()`. The app today creates an `SDL_Renderer`, which is
   **not guaranteed to be an OpenGL context**. To use the live path the window
   must be created with `SDL_WINDOW_OPENGL` + `SDL_GL_CreateContext`, and that
   context must be current on the render thread. Wiring this into `dm_app_create`
   is the first bring-up task.
2. **`xrGetOpenGLGraphicsRequirementsKHR`.** The OpenXR spec requires calling it
   (via `xrGetInstanceProcAddr`) before `xrCreateSession`. It is currently
   omitted and must be added.
3. **Session lifecycle.** `xr_poll_events` handles `READY`/`STOPPING`; it does
   **not** yet handle `EXITING`, `LOSS_PENDING`, or instance loss. Add these.
4. **Swapchain format & color.** The scaffold requests `GL_RGBA8` and uploads via
   `GL_BGRA` + `GL_UNSIGNED_INT_8_8_8_8_REV` (matches `0xAARRGGBB`). Verify the
   runtime offers that format and whether sRGB handling is needed.
5. **Frame pacing.** With a sink installed, the event-driven redraw gate should
   repaint every frame (like the AR live layer) so the runtime always gets a
   submission; wire `needs_redraw` accordingly during bring-up.

## Verification checklist (do before trusting it)

- [ ] Builds against a real OpenXR SDK (`make XR=1 DEMOD_OPENXR_SDK=…`) with no
      warnings.
- [ ] Runs against a software runtime first (e.g. Monado) — session reaches
      `FOCUSED`, no validation-layer errors.
- [ ] The UI panel appears, is legible, and tracks head-locked.
- [ ] Colors are correct (no R/B swap, no gamma shift).
- [ ] Clean teardown (`xrDestroy*`) with no leaks under the validation layer.
- [ ] On a physical HMD.

## Licensing

The OpenXR loader and headers are **Apache-2.0**, compatible with this file's
MPL-2.0. They stay isolated behind `DEMOD_XR`; the default build links no
GPU/XR code. Recorded in `THIRD_PARTY_LICENSES.md`.
