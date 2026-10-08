// SPDX-License-Identifier: MIT
//
// The performance panel: what the core reports (pt_vp_stats, read twice a second by GameRunner)
// while the game runs, and the settings that bear on it.

import SwiftUI

struct PerformanceView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if model.running {
                        let stats = model.stats
                        LabeledContent(L("Imágenes por segundo", "Frames per second"), value: String(format: "%.1f", stats.fps))
                        LabeledContent(L("CPU por imagen", "CPU per frame"), value: String(format: "%.2f ms", stats.frameMs))
                        LabeledContent(L("GPU por imagen", "GPU per frame"),
                                       value: stats.gpuMs > 0 ? String(format: "%.2f ms", stats.gpuMs) : L("No se conoce", "Unknown"))
                        LabeledContent(L("Resolución por ojo", "Resolution per eye"),
                                       value: stats.eyeWidth > 0 ? "\(stats.eyeWidth) × \(stats.eyeHeight)" : "—")
                        LabeledContent(L("Imágenes entregadas", "Frames delivered"), value: "\(stats.frames)")
                        LabeledContent(L("Fase", "Phase"), value: phaseName(stats.phase))
                    } else {
                        Label(model.started ? L("La partida ha terminado.", "The game has ended.")
                                            : L("Las estadísticas aparecen mientras el juego está en marcha.", "The statistics appear while the game runs."),
                              systemImage: "gauge.with.dots.needle.0percent")
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text(L("En vivo", "Live"))
                }

                Section {
                    LabeledContent(L("Preset", "Preset"), value: model.settings.preset.title)
                    LabeledContent(L("Escala de resolución", "Resolution scale"), value: "\(Int((model.settings.resolutionScale * 100).rounded())) %")
                    LabeledContent(L("Objetivo", "Target"), value: "\(model.settings.targetFPS) fps")
                    LabeledContent(L("Resolución dinámica", "Dynamic resolution"), value: model.settings.dynamicResolution ? L("Sí", "Yes") : L("No", "No"))
                    LabeledContent(L("Foveación", "Foveation"), value: model.settings.foveation ? L("Sí", "Yes") : L("No", "No"))
                    LabeledContent("MetalFX", value: model.settings.metalFX ? L("Sí", "Yes") : L("No", "No"))
                    LabeledContent(L("Gráficos", "Graphics"), value: "\(model.settings.graphicsPreset) · \(L("sombras", "shadows")) \(model.settings.shadows)")
                } header: {
                    Text(L("Ajustes en uso", "Settings in use"))
                } footer: {
                    Text(L("Si las imágenes por segundo caen por debajo del objetivo, baja la escala de resolución o el preset del juego, o activa la resolución dinámica.",
                           "If the frames per second fall below the target, lower the resolution scale or the game preset, or turn dynamic resolution on."))
                }
            }
            .navigationTitle(L("Rendimiento", "Performance"))
        }
    }

    private func phaseName(_ phase: String) -> String {
        switch phase {
        case "stereo": L("Juego en estéreo", "Stereo game")
        case "screen": L("Pantalla plana", "Flat screen")
        case "loading": L("Cargando", "Loading")
        case "menu": L("Menú", "Menu")
        case "": "—"
        default: phase
        }
    }
}
