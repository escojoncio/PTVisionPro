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
    bool metalfx = true;  // the eyes drawn at the image size and enlarged by MetalFX
    int fov = 100;        // percent of the views' field of view the game draws (70 to 100)
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

// After each eye is drawn: the GPU time of the eye's last measured frame (and of its passes:
// shadows, mirror, gbuffer, lighting, compose, post) and the CPU time it took to record it, for
// the launcher's performance panel and a summary in the log every ten seconds.
void ReportEye(int eye, float gpu_ms, const float pass_ms[6], float cpu_ms);

}  // namespace pt::visionos
