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

    private init() {}

    /// From the CompositorLayer's closure (formed in the App's main-actor context, so it runs on
    /// the main thread): starts the game thread with the layer renderer. The renderer is handed
    /// over unretained (the core retains it itself) as the cp_layer_renderer_t it is underneath.
    @MainActor
    static func start(layerRenderer: LayerRenderer, settings: PTSettings, model: AppModel) {
        let configuration = layerRenderer.configuration
        LogFiles.log("Immersive space: layout \(configuration.layout == .layered ? "layered" : "dedicated"), "
                     + "foveation \(configuration.isFoveationEnabled), colour \(configuration.colorFormat.rawValue)")

        let gamePath = model.gameData?.folder.path ?? ""
        let arguments = ["--game", gamePath]
        let environment = settings.environment
        LogFiles.log("Starting the core: \(arguments.joined(separator: " "))")

        let pointer = Unmanaged.passUnretained(layerRenderer).toOpaque()
        let result = withCStrings(arguments) { argv, argc in
            withCStrings(environment) { env, envCount in
                pt_vp_start(pointer, argv, argc, env, envCount)
            }
        }
        if result != 0 {
            LogFiles.log("The core did not start (error \(result))")
            model.message = L("El juego no pudo arrancar (error \(result)).", "The game could not start (error \(result)).")
            model.gameEnded()
            return
        }
        model.gameStarted()
        shared.attach(model: model)
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

    @MainActor
    private func tick() {
        guard let model else {
            detach()
            return
        }
        var raw = pt_vp_stats()
        pt_vp_stats_get(&raw)
        let stats = GameStats(fps: raw.fps, frameMs: raw.frame_ms, gpuMs: raw.gpu_ms,
                              eyeWidth: raw.eye_width, eyeHeight: raw.eye_height, frames: raw.frames,
                              phase: raw.phase.map { String(cString: $0) } ?? "")
        if stats != model.stats {
            model.stats = stats
        }
        if !pt_vp_running() {
            detach()
            model.gameEnded()
        }
    }

    @MainActor
    private func detach() {
        timer?.invalidate()
        timer = nil
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers = []
        PlayStationController.shared.onStateChange = nil
        model = nil
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
