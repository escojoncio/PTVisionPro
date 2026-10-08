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
    // Menus.
    bool dpad_up, dpad_down, dpad_left, dpad_right;
    bool l1, r1;
    int prompt_style;         // the button glyphs shown: 0 Xbox (A B X Y), 1 PlayStation, 2 Nintendo
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

/// One hand, as hand tracking sees it (ARKit's HandTrackingProvider), in the immersive space's
/// coordinates (metres): the joints the game points and pinches with.
typedef struct pt_vp_hand {
    bool tracked;
    float index_knuckle[3];   // the index finger's knuckle (where the hand's ray starts)
    float index_tip[3];
    float thumb_tip[3];
    float wrist[3];
} pt_vp_hand;

/// The newest state of one hand (0 left, 1 right), copied. While a menu is open the game draws
/// a ray from each tracked hand and a pinch clicks where it points.
void pt_vp_set_hand(int hand, const pt_vp_hand* state);

/// A look and pinch (or a direct touch) in the immersive space, for pointing at the game's menus
/// when the hands are not tracked (the player did not allow hand tracking):
/// phase 0 began or moved, 1 ended, 2 cancelled; the selection ray in the immersive space's
/// coordinates (metres; the direction need not be normalized). A pinch that starts and ends on
/// the panel the menu is on clicks where it started.
void pt_vp_spatial_event(int phase, float origin_x, float origin_y, float origin_z,
                         float direction_x, float direction_y, float direction_z);

/// Settings changed in the game's own menu, to be kept by the launcher: key and value as text
/// (keys: preset m2|m5|custom, resolution_scale, target_fps, foveation, shadows off|low|medium|high,
/// ssao, bloom, reflections, turn, snap_degrees, smooth_speed, flashlight_hand -1|0|1).
/// Called from the game thread.
void pt_vp_settings_callback(void (*cb)(const char* key, const char* value));

/// Where the core writes its log (a path inside the app's Documents, static storage), or NULL
/// before the first start.
const char* pt_vp_log_path(void);

#ifdef __cplusplus
}
#endif
