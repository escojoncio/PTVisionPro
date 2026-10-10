// SPDX-License-Identifier: MIT
//
// The Vision Pro's own settings inside the game (the headset page of its menu), and how a change
// made there reaches the launcher, which keeps every setting. Implemented in xr_host_visionos.mm.

#pragma once

#include <string>

#include "engine/platform/settings.h"

namespace pt::visionos {

// What pt.ini has no place for. Filled from the launcher's PT_VP_* variables at the start.
struct HeadsetSettings {
    int preset = 0;  // 0 Vision Pro M2, 1 Vision Pro M5, 2 custom
    float resolution_scale = 0.6f;
    int target_fps = 90;
    bool foveation = true;
    bool metalfx = false;  // (old: MetalFX spatial over the whole eye; always off, see `aa`)
    int fov = 100;        // percent of the views' field of view the game draws (70 to 100)
    // The game's own foveation: each eye drawn whole at a low density (`periphery`, percent of
    // the image size) and a sharp zone around its forward axis again (`center_deg` degrees
    // across, height in the view's proportions) at its own density (`center_res`, percent of the
    // image size), independent of the periphery's; the composition lays it over the wide view.
    bool game_foveation = true;
    int periphery = 20;    // 10 to 50
    int center_deg = 40;   // 20 to 70: the sharp circle's diameter
    int center_up = -8;    // -20 to 10: its centre's degrees above the eye's forward axis (below if negative)
    int center_res = 100;  // 50 to 100
    bool show_border = false;  // a red frame where the sharp zone ends (the menu; not kept)
    // Native HDR: the scene's real light above white, up to this percent of SDR white (100: off,
    // up to the headset's 200). Not part of a preset: it costs almost nothing.
    int hdr = 200;
    // Antialiasing of the sharp views (the insets, or the eyes without the game's foveation):
    // 0 FXAA; 1 MetalFX temporal at the full size (antialiasing only); 2-4 MetalFX temporal
    // drawing at 85, 75 or 67 % and rebuilding the full size from the past frames.
    int aa = 1;
    // The scene's depth handed to the compositor with each picture, so its reprojection (45 to
    // 90, and every picture's correction to the latest head pose) moves near things correctly.
    bool scene_depth = true;
    // Dynamic resolution: the eyes drawn smaller while the GPU cannot keep the frame rate.
    bool dynamic_resolution = false;
    // The headset is an M5 (its preset is offered only then).
    bool device_m5 = false;
};

// What each antialiasing step draws, as a fraction of the sharp view's size (HeadsetSettings::aa).
inline float AaScale(int aa) {
    static constexpr float kScales[5] = {1.0f, 1.0f, 0.85f, 0.75f, 0.67f};
    return kScales[aa < 0 ? 0 : aa > 4 ? 4 : aa];
}

// The launcher's settings into the game's, after pt.ini was read.
void ApplySettings(AppSettings& settings);

HeadsetSettings& Headset();

// Tells the app a setting changed in the game's menu (keys as PTSettings.swift names them).
void SettingChanged(const char* key, const std::string& value);

// After a graphics change in the menu: the app gets the new values, and the preset turns custom
// when they are no longer the preset's.
void GraphicsChanged(const AppSettings& settings);

// A preset (0 M2, 1 M5, 2 custom) into the settings, and to the app.
void ApplyPreset(int preset, AppSettings& settings);

// The menu's "recentre": the game centres on the head again at the next frame.
void RequestRecenter();

// After each view is drawn (`view` of `views`: the eyes, then their insets with the game's
// foveation): the GPU time of its last measured frame (and of its passes: shadows, mirror,
// gbuffer, lighting, compose, post) and the CPU time it took to record it, for the launcher's
// performance panel and a summary in the log every ten seconds.
void ReportEye(int view, int views, float gpu_ms, const float pass_ms[6], float cpu_ms);

}  // namespace pt::visionos
