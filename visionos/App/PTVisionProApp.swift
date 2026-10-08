// SPDX-License-Identifier: MIT
//
// P.T. on Apple Vision Pro: a launcher window (the game's data, the settings, the controller,
// the performance panel and the log) and a full immersive space the game is shown in. The game
// core (C++, Vulkan on MoltenVK) draws into the space's layer renderer itself.

import CompositorServices
import SwiftUI

@main
struct PTVisionProApp: App {
    @State private var model = AppModel()
    @State private var immersion: ImmersionStyle = .full

    var body: some Scene {
        WindowGroup(id: AppModel.launcherID) {
            LauncherView()
                .environment(model)
        }
        .defaultSize(width: 1180, height: 760)

        ImmersiveSpace(id: AppModel.immersiveSpaceID) {
            CompositorLayer(configuration: GameLayerConfiguration(
                foveation: model.settings.foveation,
                compositorQuality: model.settings.compositorQuality)) { layerRenderer in
                // On the main actor whatever thread the layer is handed over on: the core starts
                // its own thread and waits for the layer to run.
                Task { @MainActor [model] in
                    GameRunner.start(layerRenderer: layerRenderer, settings: model.settings, model: model)
                }
            }
        }
        .immersionStyle(selection: $immersion, in: .full)
        .upperLimbVisibility(model.settings.showHands ? .visible : .hidden)
        .persistentSystemOverlays(.hidden)
    }
}
