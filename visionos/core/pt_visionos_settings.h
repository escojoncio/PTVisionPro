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
    bool metalfx = false;  // the eyes drawn at the image size and enlarged by MetalFX
    int fov = 100;        // percent of the views' field of view the game draws (70 to 100)
    // The game's own foveation: each eye drawn wide at a lower density (`periphery`, percent of
    // the image size) and its centre again (`center`, percent of the eye's field of view across)
    // at the same pixel size; the composition lays the centre over the wide view.
    bool game_foveation = true;
    int periphery = 45;  // 30 to 70
    int center = 45;     // 30 to 60
    // Dynamic resolution: the eyes drawn smaller while the GPU cannot keep the frame rate.
    bool dynamic_resolution = false;
    // The headset is an M5 (its preset is offered only then).
    bool device_m5 = false;
};

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
