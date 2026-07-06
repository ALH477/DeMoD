// SPDX-License-Identifier: MPL-2.0
/*
 * DeMoD UI Framework — OpenXR quad-layer present sink (opt-in, make XR=1)
 * ─────────────────────────────────────────────────────────────────────────
 * Presents the pure-CPU framebuffer to an OpenXR runtime as a head-locked quad
 * layer: each frame the ARGB8888 pixels are uploaded to an OpenGL swapchain
 * texture and submitted via xrEndFrame. This lets the software-rendered UI float
 * as a panel inside a VR/AR headset without the framework itself gaining a GPU
 * render path — the only GPU work is one texture upload, isolated in this file.
 *
 * ┌──────────────────────────────────────────────────────────────────────────┐
 * │ STATUS: UNTESTED REFERENCE SCAFFOLD.                                       │
 * │ Never exercised on hardware in-tree. Without the OpenXR SDK on the include │
 * │ path this compiles to a no-op stub (dm_xr_sink_create returns NULL → the   │
 * │ app keeps the SDL window). The live path needs an OpenXR runtime + headset │
 * │ + an OpenGL context on the SDL window, and MUST be validated on real       │
 * │ hardware before use. See docs/xr-sink.md for the build recipe, the         │
 * │ integration requirements (GL context), and the completion checklist.       │
 * └──────────────────────────────────────────────────────────────────────────┘
 *
 * Licensing: the OpenXR loader + headers are Apache-2.0 (compatible with this
 * MPL-2.0 file); it stays fully isolated behind DEMOD_XR so the default build
 * links no GPU/XR code. Recorded in THIRD_PARTY_LICENSES.md.
 *
 * Copyright (c) 2026 DeMoD LLC. Licensed under the Mozilla Public License, v. 2.0.
 */
#include "demod/app.h"

#ifdef DEMOD_XR

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* Detect the OpenXR SDK. XR=1 without DEMOD_OPENXR_SDK set → the stub below. */
#if defined(__has_include)
#  if __has_include(<openxr/openxr.h>)
#    define DEMOD_HAVE_OPENXR 1
#  endif
#endif

#ifndef DEMOD_HAVE_OPENXR
/* ── Stub: built with XR=1 but no OpenXR SDK ──────────────────────────────── */
DmPresentSink *dm_xr_sink_create(DmApp *app) {
    (void)app;
    fprintf(stderr,
        "[xr] XR=1 but built without the OpenXR SDK — set DEMOD_OPENXR_SDK to a\n"
        "     valid SDK path and rebuild. Falling back to the SDL window.\n");
    return NULL;
}
#else
/* ── Live path (UNTESTED) — OpenGL quad-layer sink ────────────────────────── */
#define XR_USE_GRAPHICS_API_OPENGL
#define XR_USE_PLATFORM_XLIB
#include <X11/Xlib.h>
#include <GL/glx.h>
#include <GL/gl.h>
#include <openxr/openxr.h>
#include <openxr/openxr_platform.h>

typedef struct {
    XrInstance                 instance;
    XrSystemId                 system;
    XrSession                  session;
    XrSpace                    space;       /* VIEW space → head-locked quad */
    XrSwapchain                swapchain;
    XrSwapchainImageOpenGLKHR *images;
    uint32_t                   image_count;
    int32_t                    width, height;
    GLuint                     fbo;
    XrSessionState             state;
    int                        session_running;
} XrSink;

#define XR_OK(call) do {                                              \
        XrResult _r = (call);                                         \
        if (XR_FAILED(_r)) {                                          \
            fprintf(stderr, "[xr] %s failed (%d)\n", #call, (int)_r); \
            goto fail;                                                \
        }                                                             \
    } while (0)

/* Pump session-state events; drive the READY→begin / STOPPING→end lifecycle.
 * NOTE (UNTESTED): a production sink must also handle XR_SESSION_STATE_EXITING /
 * LOSS_PENDING and instance-loss; those are left as TODO for hardware bring-up. */
static void xr_poll_events(XrSink *s) {
    XrEventDataBuffer ev = { .type = XR_TYPE_EVENT_DATA_BUFFER };
    while (xrPollEvent(s->instance, &ev) == XR_SUCCESS) {
        if (ev.type == XR_TYPE_EVENT_DATA_SESSION_STATE_CHANGED) {
            const XrEventDataSessionStateChanged *e =
                (const XrEventDataSessionStateChanged *)&ev;
            s->state = e->state;
            if (e->state == XR_SESSION_STATE_READY) {
                XrSessionBeginInfo bi = {
                    .type = XR_TYPE_SESSION_BEGIN_INFO,
                    .primaryViewConfigurationType =
                        XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO,
                };
                if (!XR_FAILED(xrBeginSession(s->session, &bi)))
                    s->session_running = 1;
            } else if (e->state == XR_SESSION_STATE_STOPPING) {
                xrEndSession(s->session);
                s->session_running = 0;
            }
        }
        ev = (XrEventDataBuffer){ .type = XR_TYPE_EVENT_DATA_BUFFER };
    }
}

static void xr_present(void *ctx, const DmFramebuffer *fb) {
    XrSink *s = (XrSink *)ctx;
    xr_poll_events(s);
    if (!s->session_running) return;

    XrFrameState fs = { .type = XR_TYPE_FRAME_STATE };
    XrFrameWaitInfo fwi = { .type = XR_TYPE_FRAME_WAIT_INFO };
    if (XR_FAILED(xrWaitFrame(s->session, &fwi, &fs))) return;

    XrFrameBeginInfo fbi = { .type = XR_TYPE_FRAME_BEGIN_INFO };
    xrBeginFrame(s->session, &fbi);

    XrCompositionLayerQuad quad = { .type = XR_TYPE_COMPOSITION_LAYER_QUAD };
    const XrCompositionLayerBaseHeader *layers[1] = { NULL };
    uint32_t layer_count = 0;

    if (fs.shouldRender) {
        uint32_t idx = 0;
        XrSwapchainImageAcquireInfo ai = { .type = XR_TYPE_SWAPCHAIN_IMAGE_ACQUIRE_INFO };
        XrSwapchainImageWaitInfo    wi = { .type = XR_TYPE_SWAPCHAIN_IMAGE_WAIT_INFO,
                                           .timeout = XR_INFINITE_DURATION };
        if (!XR_FAILED(xrAcquireSwapchainImage(s->swapchain, &ai, &idx)) &&
            !XR_FAILED(xrWaitSwapchainImage(s->swapchain, &wi))) {
            /* Upload the CPU framebuffer into the swapchain's GL texture.
               ARGB8888 (0xAARRGGBB) matches GL_BGRA + UNSIGNED_INT_8_8_8_8_REV. */
            glBindTexture(GL_TEXTURE_2D, s->images[idx].image);
            glPixelStorei(GL_UNPACK_ROW_LENGTH, fb->stride);
            glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, fb->width, fb->height,
                            GL_BGRA, GL_UNSIGNED_INT_8_8_8_8_REV, fb->pixels);
            glPixelStorei(GL_UNPACK_ROW_LENGTH, 0);
            glBindTexture(GL_TEXTURE_2D, 0);

            XrSwapchainImageReleaseInfo ri = { .type = XR_TYPE_SWAPCHAIN_IMAGE_RELEASE_INFO };
            xrReleaseSwapchainImage(s->swapchain, &ri);

            /* A ~1m-wide head-locked panel 1.5 m in front of the viewer. */
            quad.layerFlags        = XR_COMPOSITION_LAYER_BLEND_TEXTURE_SOURCE_ALPHA_BIT;
            quad.space             = s->space;
            quad.eyeVisibility     = XR_EYE_VISIBILITY_BOTH;
            quad.subImage.swapchain = s->swapchain;
            quad.subImage.imageRect.offset = (XrOffset2Di){ 0, 0 };
            quad.subImage.imageRect.extent = (XrExtent2Di){ s->width, s->height };
            quad.pose.orientation  = (XrQuaternionf){ 0, 0, 0, 1 };
            quad.pose.position     = (XrVector3f){ 0.0f, 0.0f, -1.5f };
            quad.size              = (XrExtent2Df){ 1.0f,
                                        1.0f * (float)s->height / (float)s->width };
            layers[0]   = (const XrCompositionLayerBaseHeader *)&quad;
            layer_count = 1;
        }
    }

    XrFrameEndInfo fei = {
        .type                 = XR_TYPE_FRAME_END_INFO,
        .displayTime          = fs.predictedDisplayTime,
        .environmentBlendMode = XR_ENVIRONMENT_BLEND_MODE_OPAQUE,
        .layerCount           = layer_count,
        .layers               = layers,
    };
    xrEndFrame(s->session, &fei);
}

static void xr_destroy(void *ctx) {
    XrSink *s = (XrSink *)ctx;
    if (!s) return;
    if (s->swapchain) xrDestroySwapchain(s->swapchain);
    if (s->space)     xrDestroySpace(s->space);
    if (s->session)   xrDestroySession(s->session);
    if (s->instance)  xrDestroyInstance(s->instance);
    free(s->images);
    free(s);
}

DmPresentSink *dm_xr_sink_create(DmApp *app) {
    XrSink *s = (XrSink *)calloc(1, sizeof(*s));
    DmPresentSink *sink = (DmPresentSink *)calloc(1, sizeof(*sink));
    if (!s || !sink) { free(s); free(sink); return NULL; }
    s->width  = app->fb->width;
    s->height = app->fb->height;
    s->state  = XR_SESSION_STATE_UNKNOWN;

    const char *exts[] = { XR_KHR_OPENGL_ENABLE_EXTENSION_NAME };
    XrInstanceCreateInfo ici = {
        .type = XR_TYPE_INSTANCE_CREATE_INFO,
        .applicationInfo = { .applicationName = "DeMoD UI",
                             .applicationVersion = 1,
                             .apiVersion = XR_CURRENT_API_VERSION },
        .enabledExtensionCount = 1,
        .enabledExtensionNames = exts,
    };
    XR_OK(xrCreateInstance(&ici, &s->instance));

    XrSystemGetInfo sgi = { .type = XR_TYPE_SYSTEM_GET_INFO,
                            .formFactor = XR_FORM_FACTOR_HEAD_MOUNTED_DISPLAY };
    XR_OK(xrGetSystem(s->instance, &sgi, &s->system));

    /* OpenGL graphics binding from the current GLX context. REQUIRES the SDL
       window to own an OpenGL context (SDL_WINDOW_OPENGL + SDL_GL_CreateContext)
       — see docs/xr-sink.md. UNTESTED: verify the display/drawable/context are
       the ones OpenXR expects on the target runtime. */
    XrGraphicsBindingOpenGLXlibKHR gl = {
        .type       = XR_TYPE_GRAPHICS_BINDING_OPENGL_XLIB_KHR,
        .xDisplay   = XOpenDisplay(NULL),
        .glxContext = glXGetCurrentContext(),
        .glxDrawable = glXGetCurrentDrawable(),
    };
    if (!gl.glxContext) {
        fprintf(stderr, "[xr] no current GL context — the app must create an "
                        "OpenGL SDL window (see docs/xr-sink.md).\n");
        goto fail;
    }
    /* xrGetOpenGLGraphicsRequirementsKHR must be called before session create;
       loaded via xrGetInstanceProcAddr. Omitted here — add during bring-up. */

    XrSessionCreateInfo sci = { .type = XR_TYPE_SESSION_CREATE_INFO,
                                .next = &gl, .systemId = s->system };
    XR_OK(xrCreateSession(s->instance, &sci, &s->session));

    XrReferenceSpaceCreateInfo rsci = {
        .type = XR_TYPE_REFERENCE_SPACE_CREATE_INFO,
        .referenceSpaceType = XR_REFERENCE_SPACE_TYPE_VIEW,   /* head-locked */
        .poseInReferenceSpace = { .orientation = { 0, 0, 0, 1 } },
    };
    XR_OK(xrCreateReferenceSpace(s->session, &rsci, &s->space));

    XrSwapchainCreateInfo scci = {
        .type        = XR_TYPE_SWAPCHAIN_CREATE_INFO,
        .usageFlags  = XR_SWAPCHAIN_USAGE_COLOR_ATTACHMENT_BIT |
                       XR_SWAPCHAIN_USAGE_TRANSFER_DST_BIT,
        .format      = GL_RGBA8,
        .sampleCount = 1,
        .width       = s->width,
        .height      = s->height,
        .faceCount   = 1,
        .arraySize   = 1,
        .mipCount    = 1,
    };
    XR_OK(xrCreateSwapchain(s->session, &scci, &s->swapchain));

    XR_OK(xrEnumerateSwapchainImages(s->swapchain, 0, &s->image_count, NULL));
    s->images = (XrSwapchainImageOpenGLKHR *)calloc(s->image_count, sizeof(*s->images));
    if (!s->images) goto fail;
    for (uint32_t i = 0; i < s->image_count; i++)
        s->images[i].type = XR_TYPE_SWAPCHAIN_IMAGE_OPENGL_KHR;
    XR_OK(xrEnumerateSwapchainImages(s->swapchain, s->image_count, &s->image_count,
                                     (XrSwapchainImageBaseHeader *)s->images));

    sink->ctx     = s;
    sink->present = xr_present;
    sink->destroy = xr_destroy;
    fprintf(stderr, "[xr] OpenXR quad-layer sink active (%dx%d) — UNTESTED path\n",
            s->width, s->height);
    return sink;

fail:
    xr_destroy(s);
    free(sink);
    return NULL;
}
#endif /* DEMOD_HAVE_OPENXR */
#endif /* DEMOD_XR */
