// SPDX-License-Identifier: MIT
//
// Starting the game core in the immersive space, and everything that flows between the app and
// it while it runs: the layer renderer and the settings at the start, the controller's changes
// and the app's foreground state while it runs, the haptic pulses and the statistics back.
// The core draws every frame itself; the app never touches the layer renderer again.

import CompositorServices
import Foundation
import UIKit

final class GameRunner: @unchecked Sendable {
    static let shared = GameRunner()

    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private weak var model: AppModel?
    /// The layer the game draws to now, to notice its space closing (the core keeps it alive).
    private weak var layer: LayerRenderer?

    private init() {}

    /// From the CompositorLayer's closure (formed in the App's main-actor context, so it runs on
    /// the main thread): starts the game thread with the layer renderer. The renderer is handed
    /// over unretained (the core retains it itself) as the cp_layer_renderer_t it is underneath.
    @MainActor
    static func start(layerRenderer: LayerRenderer, settings: PTSettings, model: AppModel) {
        let configuration = layerRenderer.configuration
        LogFiles.log("Immersive space: layout \(configuration.layout == .layered ? "layered" : "dedicated"), "
                     + "foveation \(configuration.isFoveationEnabled), colour \(configuration.colorFormat.rawValue), "
                     + "render quality \(layerRenderer.renderQuality.rawValue) (max \(configuration.maxRenderQuality.rawValue))")
        // The render quality the settings ask for (with foveation; 0 leaves the system's).
        if configuration.isFoveationEnabled && settings.compositorQuality > 0 {
            let quality = min(settings.compositorQuality, configuration.maxRenderQuality.rawValue)
            layerRenderer.renderQuality = .init(quality)
            LogFiles.log("Render quality set to \(quality)")
        }
        listen(to: layerRenderer)

        // The game is already running (its space was closed and opened again): it goes on in
        // the new one, from where it was paused.
        if model.running {
            let pointer = Unmanaged.passUnretained(layerRenderer).toOpaque()
            if pt_vp_attach_layer(pointer) == 0 {
                LogFiles.log("The game goes on in the new immersive space")
                shared.layer = layerRenderer
                model.message = nil
                // The hands and the Sense controllers are tracked again (a closed space's
                // tracking does not come back by itself; the Sense ones restart on the next tick).
                HandTracking.shared.stop()
                HandTracking.shared.start()
                SenseTracking.shared.stop()
            } else {
                LogFiles.log("The game had ended before its space opened again")
                model.gameEnded(code: pt_vp_exit_code())
            }
            return
        }

        let gamePath = model.gameData?.folder.path ?? ""
        var arguments = ["--game", gamePath]
        // The saves in VPS4/Partidas/CUSA01127 (they outlive the app); without VPS4, in the app.
        if let saves = VPS4Folder.shared.saves(for: GameData.folderName) {
            arguments += ["--save-dir", saves.path]
        }
        let environment = settings.environment
        LogFiles.log("Starting the core: \(arguments.joined(separator: " "))")

        // Settings changed in the game's own menu: kept by the launcher like its own.
        pt_vp_settings_callback { key, value in
            guard let key, let value else { return }
            let k = String(cString: key)
            let v = String(cString: value)
            Task { @MainActor in
                GameRunner.shared.settingFromGame(key: k, value: v)
            }
        }

        let pointer = Unmanaged.passUnretained(layerRenderer).toOpaque()
        let result = withCStrings(arguments) { argv, argc in
            withCStrings(environment) { env, envCount in
                pt_vp_start(pointer, argv, argc, env, envCount)
            }
        }
        if result != 0 {
            LogFiles.log("The core did not start (error \(result))")
            model.message = L("El juego no pudo arrancar (error \(result)).", "The game could not start (error \(result)).")
            model.gameEnded(code: result)
            return
        }
        shared.layer = layerRenderer
        model.gameStarted()
        shared.attach(model: model)
        // The hands, for pointing at the game's menus.
        HandTracking.shared.start()
    }

    /// Looks and pinches, for the game's menus: the selection ray of each one to the core, which
    /// clicks the menu where a pinch starts and ends on it.
    @MainActor
    private static func listen(to layerRenderer: LayerRenderer) {
        layerRenderer.onSpatialEvent = { events in
            for event in events {
                let phase: Int32
                switch event.phase {
                case .active: phase = 0
                case .ended: phase = 1
                default: phase = 2
                }
                guard let ray = event.selectionRay else {
                    if phase != 0 {
                        pt_vp_spatial_event(phase, 0, 0, 0, 0, 0, -1)
                    }
                    continue
                }
                pt_vp_spatial_event(phase,
                                    Float(ray.origin.x), Float(ray.origin.y), Float(ray.origin.z),
                                    Float(ray.direction.x), Float(ray.direction.y), Float(ray.direction.z))
            }
        }
    }

    /// Everything that goes on while the game runs. On the main thread.
    @MainActor
    private func attach(model: AppModel) {
        self.model = model

        // The controller: what it says now, and every change from here on.
        let controllers = PlayStationController.shared
        controllers.onStateChange = { state in
            var copy = state
            pt_vp_set_controller(&copy)
        }
        var current = controllers.currentState
        pt_vp_set_controller(&current)

        // The game's haptic pulses, to the controller's motors.
        pt_vp_haptics_callback { hand, amplitude, seconds in
            PlayStationController.shared.playHaptic(hand: Int(hand), amplitude: amplitude, seconds: seconds)
        }

        // Whether the app is in front.
        pt_vp_set_foreground(UIApplication.shared.applicationState == .active)
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            pt_vp_set_foreground(true)
        })
        observers.append(center.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { _ in
            pt_vp_set_foreground(false)
        })

        // The statistics, and noticing the game thread's end.
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.tick()
            }
        }
    }

    /// A setting the player changed in the game's menu, into the launcher's settings (which are
    /// saved, and given to the game the next time it starts).
    @MainActor
    func settingFromGame(key: String, value: String) {
        guard let model else { return }
        var s = model.settings
        let flag = value != "0"
        switch key {
        case "preset": s.preset = PTSettings.Preset(rawValue: value) ?? .custom
        case "resolution_scale": s.resolutionScale = Double(value) ?? s.resolutionScale
        case "target_fps": s.targetFPS = Int(value) ?? s.targetFPS
        case "foveation": s.foveation = flag
        case "metalfx": s.metalFX = flag
        case "fov": s.fov = Int(value) ?? s.fov
        case "game_foveation": s.gameFoveation = flag
        case "periphery": s.periphery = Int(value) ?? s.periphery
        case "center": s.center = Int(value) ?? s.center
        case "shadows": s.shadows = value
        case "ssao": s.ssao = flag
        case "bloom": s.bloom = flag
        case "reflections": s.reflections = flag
        case "turn": s.turnMode = Int(value) ?? s.turnMode
        case "snap_degrees": s.snapDegrees = Int(value) ?? s.snapDegrees
        case "smooth_speed": s.smoothSpeed = Int(value) ?? s.smoothSpeed
        case "flashlight_hand": s.flashlightHand = Int(value) ?? s.flashlightHand
        default:
            LogFiles.log("Setting from the game not known to the launcher: \(key)=\(value)")
            return
        }
        if s != model.settings {
            model.settings = s
        }
    }

    @MainActor
    private func tick() {
        guard let model else {
            detach()
            return
        }
        // The PlayStation VR2 Sense controllers connected now, tracked in space (does nothing
        // while they are the same ones).
        SenseTracking.shared.track(PlayStationController.shared.senses)
        var raw = pt_vp_stats()
        pt_vp_stats_get(&raw)
        let stats = GameStats(fps: raw.fps, frameMs: raw.frame_ms, gpuMs: raw.gpu_ms,
                              eyeWidth: raw.eye_width, eyeHeight: raw.eye_height, frames: raw.frames,
                              phase: raw.phase.map { String(cString: $0) } ?? "")
        if stats != model.stats {
            model.stats = stats
        }
        if !pt_vp_running() {
            let code = pt_vp_exit_code()
            detach()
            model.gameEnded(code: code)
            return
        }
        // The space closed under the game (the Digital Crown, or the system): it waits paused,
        // and the launcher offers to go back to it.
        if model.immersiveOpen, let layer, layer.state == .invalidated {
            model.immersiveEnded()
        }
    }

    @MainActor
    private func detach() {
        HandTracking.shared.stop()
        SenseTracking.shared.stop()
        timer?.invalidate()
        timer = nil
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers = []
        PlayStationController.shared.onStateChange = nil
        model = nil
        layer = nil
    }
}

/// Strings as a C array of C strings (const char* const*), for the time of the call.
private func withCStrings<R>(_ strings: [String], _ body: (UnsafePointer<UnsafePointer<CChar>?>, Int32) -> R) -> R {
    var pointers: [UnsafeMutablePointer<CChar>?] = strings.map { strdup($0) }
    defer {
        for pointer in pointers {
            free(pointer)
        }
    }
    return pointers.withUnsafeMutableBufferPointer { buffer -> R in
        buffer.withMemoryRebound(to: UnsafePointer<CChar>?.self) { rebound in
            body(UnsafePointer(rebound.baseAddress!), Int32(rebound.count))
        }
    }
}
