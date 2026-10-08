// SPDX-License-Identifier: MIT
//
// The contract between the visionOS app (Swift) and the game core (C++, libpt_visionos.a).
// The app owns the window, the immersive space, the settings and the controller; the core owns
// the game thread, Vulkan (through MoltenVK) and the whole composition of each frame into the
// CompositorLayer's drawables. Nothing here is Objective-C: the layer renderer travels as void*.
//
// Threading: pt_vp_start is called once, from the CompositorLayer's closure (the app's main
// thread or whichever thread Compositor Services uses for it); everything else may be called
// from any thread, and the core keeps its own copies of what it is given.

#pragma once
#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// The controller as the game reads it: a PlayStation controller or the two PlayStation VR2
/// Sense controllers, already mapped to the game's actions. Sticks are -1..1, right and up
/// positive (GameController's convention). Hand poses, when the app can track them, are in the
/// immersive space's world frame, metres, quaternion x,y,z,w; hand 0 is the left one.
typedef struct pt_vp_controller {
    bool active;              // a controller is connected and this state is current
    float move_x, move_y;     // left stick, -1..1
    float turn_x, turn_y;     // right stick, -1..1
    bool interact;            // Cross
    bool back;                // Circle
    bool menu;                // OPTIONS
    bool zoom;                // R3
    bool gouge;               // Square
    bool triangle;            // Triangle
    bool settings;            // touchpad / Create / Share
    bool hand_valid[2];
    float hand_pos[2][3];
    float hand_rot[2][4];     // quaternion x,y,z,w
} pt_vp_controller;

/// What the launcher's performance panel shows.
typedef struct pt_vp_stats {
    double fps;               // frames handed to the headset per second
    double frame_ms;          // CPU time of the game loop per frame
    double gpu_ms;            // GPU time per frame when known, else 0
    uint32_t eye_width, eye_height;
    uint64_t frames;          // frames handed to the headset since the start
    const char* phase;        // "stereo" | "screen" | "loading" | "menu" (static storage)
} pt_vp_stats;

/// Starts the game thread. layer_renderer: the cp_layer_renderer_t of the immersive space (an
/// unretained pointer the core retains itself). argv: extra arguments for the core, for example
/// "--game" and the data folder's path (argv[0] is NOT a program name). env: "NAME=value"
/// strings the core takes as its settings (the PT_VP_* variables PTSettings exports).
/// Returns 0 if the game thread started. May be called once per process: a second call returns
/// nonzero.
int pt_vp_start(void* layer_renderer, const char* const* argv, int argc,
                const char* const* env, int env_count);

/// Asks the game thread to end (saving what it has to); pt_vp_running turns false once it has.
void pt_vp_request_quit(void);

/// Whether the game thread is alive.
bool pt_vp_running(void);

/// The newest controller state (copied).
void pt_vp_set_controller(const pt_vp_controller* state);

/// The game's haptics: hand 0 left, 1 right, -1 both; amplitude 0..1; seconds of the pulse.
/// Called from the game thread.
void pt_vp_haptics_callback(void (*cb)(int hand, float amplitude, float seconds));

/// The newest statistics (copied into *out).
void pt_vp_stats_get(pt_vp_stats* out);

/// Whether the app is in front (false: the player took the headset off or left the space; the
/// game pauses its clock and its audio as the settings say).
void pt_vp_set_foreground(bool active);

/// Where the core writes its log (a path inside the app's Documents, static storage), or NULL
/// before the first start.
const char* pt_vp_log_path(void);

#ifdef __cplusplus
}
#endif
