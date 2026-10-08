// SPDX-License-Identifier: MIT
//
// How the immersive space is drawn. The app draws nothing itself: the game core gets the
// layer renderer (GameRunner) and composes every frame into its drawables through MoltenVK and
// Metal. What is decided here is what those drawables are: both eyes in one layered texture
// where the headset supports it, half-float colour, 32-bit depth, and foveation (where the eyes
// look is drawn at the drawable's full resolution, the rest at less) up to the render quality
// the settings ask for.

import CompositorServices
import SwiftUI

struct GameLayerConfiguration: CompositorLayerConfiguration {
    let foveation: Bool
    let renderQuality: Float

    func makeConfiguration(capabilities: LayerRenderer.Capabilities,
                           configuration: inout LayerRenderer.Configuration) {
        configuration.depthFormat = .depth32Float
        configuration.colorFormat = .rgba16Float

        let foveated = foveation && capabilities.supportsFoveation
        configuration.isFoveationEnabled = foveated
        if foveated {
            configuration.maxRenderQuality = .init(min(max(renderQuality, 0.1), 1.0))
        }
        let options: LayerRenderer.Capabilities.SupportedLayoutsOptions = foveated ? [.foveationEnabled] : []
        let layouts = capabilities.supportedLayouts(options: options)
        configuration.layout = layouts.contains(.layered) ? .layered : .dedicated
    }
}
