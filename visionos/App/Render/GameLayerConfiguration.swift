// SPDX-License-Identifier: MIT
//
// How the immersive space is drawn. The app draws nothing itself: the game core gets the
// layer renderer (GameRunner) and composes every frame into its drawables through MoltenVK and
// Metal. What is decided here is what those drawables are: both eyes in one layered texture
// where the headset supports it, half-float colour, 32-bit depth, and foveation (where the eyes
// look is drawn at the drawable's full resolution, the rest at less) with the render quality
// the settings ask for (visionOS 26; 0 leaves the system's own).

import CompositorServices
import SwiftUI

struct GameLayerConfiguration: CompositorLayerConfiguration {
    let foveation: Bool
    /// 0: the system's own; else 0.5 to 1.
    let compositorQuality: Float

    func makeConfiguration(capabilities: LayerRenderer.Capabilities,
                           configuration: inout LayerRenderer.Configuration) {
        configuration.depthFormat = .depth32Float
        configuration.colorFormat = .rgba16Float

        let foveated = foveation && capabilities.supportsFoveation
        configuration.isFoveationEnabled = foveated
        // The render quality only works with foveation. It sets how large the drawables are made
        // (the game's own pictures are sized from them).
        let systemQuality = configuration.maxRenderQuality.rawValue
        if foveated && compositorQuality > 0 {
            configuration.maxRenderQuality = .init(min(max(compositorQuality, 0.1), 1.0))
        }
        LogFiles.log("Layer: foveation \(foveated), max render quality \(configuration.maxRenderQuality.rawValue) "
                     + "(system default \(systemQuality))")
        let options: LayerRenderer.Capabilities.SupportedLayoutsOptions = foveated ? [.foveationEnabled] : []
        let layouts = capabilities.supportedLayouts(options: options)
        configuration.layout = layouts.contains(.layered) ? .layered : .dedicated
    }
}
