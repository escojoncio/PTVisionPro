// SPDX-License-Identifier: MIT
//
// Every setting, changed in place (there is nothing to edit in a file). Each change goes to
// PTSettings in UserDefaults through the model; a game started afterwards uses them.

import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    /// A rough size of the drawable the headset recommends for one eye at render quality 1,
    /// for the estimate shown next to the resolution scale.
    private static let baseEyeWidth = 1920.0
    private static let baseEyeHeight = 1824.0

    var body: some View {
        NavigationStack {
            Form {
                presetSection
                pictureSection
                graphicsSection
                headsetSection
                controllerSection
                gameSection
                diagnosticsSection
            }
            .navigationTitle(L("Ajustes", "Settings"))
        }
    }

    // MARK: - Sections

    private var presetSection: some View {
        Section {
            Picker(L("Preset", "Preset"), selection: Binding(
                get: { model.settings.preset },
                set: { model.apply(preset: $0) })) {
                Text("M2").tag(PTSettings.Preset.m2)
                Text("M5").tag(PTSettings.Preset.m5)
                Text(L("Personalizado", "Custom")).tag(PTSettings.Preset.custom)
            }
            .pickerStyle(.segmented)
            LabeledContent(L("Visor detectado", "Detected headset")) {
                HStack(spacing: 8) {
                    Text(model.detectedPreset == .m5 ? "Apple Vision Pro · M5" : "Apple Vision Pro · M2")
                        .font(.caption)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(.quaternary, in: .capsule)
                    if !model.hardwareModel.isEmpty {
                        Text(model.hardwareModel)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Button(L("Restablecer preset", "Reset preset")) {
                model.apply(preset: model.detectedPreset)
            }
        } header: {
            Text(L("Preset", "Preset"))
        } footer: {
            Text(L("M2 es el primer Apple Vision Pro; M5 el posterior. Al cambiar un ajuste de imagen, gráficos o visor, el preset pasa a Personalizado.",
                   "M2 is the first Apple Vision Pro; M5 the later one. Changing a picture, graphics or headset setting makes the preset Custom."))
        }
    }

    private var pictureSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                LabeledContent(L("Escala de resolución", "Resolution scale")) {
                    Text("\(Int((model.settings.resolutionScale * 100).rounded())) %")
                        .monospacedDigit()
                }
                Slider(value: double(\.resolutionScale), in: 0.5...2.0, step: 0.05)
                Text(L("Unos \(estimatedWidth) × \(estimatedHeight) por ojo", "About \(estimatedWidth) × \(estimatedHeight) per eye"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Toggle(L("Resolución dinámica", "Dynamic resolution"), isOn: bool(\.dynamicResolution))
            Picker(L("Imágenes por segundo", "Frames per second"), selection: int(\.targetFPS)) {
                Text("90").tag(90)
                Text("45").tag(45)
            }
            LabeledContent(L("Campo de visión", "Field of view")) {
                Stepper("\(model.settings.fov) %", value: int(\.fov), in: 70...100, step: 5)
            }
            LabeledContent(L("Nitidez", "Sharpness")) {
                HStack {
                    Slider(value: double(\.sharpen), in: 0...1, step: 0.1)
                        .frame(width: 240)
                    Text(String(format: "%.1f", model.settings.sharpen))
                        .monospacedDigit()
                        .frame(width: 40)
                }
            }
        } header: {
            Text(L("Imagen", "Picture"))
        } footer: {
            Text(L("La escala es relativa a la resolución que recomienda el visor. 45 fps dibuja una imagen cada dos refrescos.",
                   "The scale is relative to the resolution the headset recommends. 45 fps draws one picture every other refresh."))
        }
    }

    private var graphicsSection: some View {
        Section {
            Picker(L("Preset del juego", "Game preset"), selection: string(\.graphicsPreset)) {
                Text(L("Bajo", "Low")).tag("low")
                Text(L("Medio", "Medium")).tag("medium")
                Text(L("Alto", "High")).tag("high")
                Text("Ultra").tag("ultra")
            }
            Picker(L("Sombras", "Shadows"), selection: string(\.shadows)) {
                Text(L("Sin sombras", "Off")).tag("off")
                Text(L("Bajas", "Low")).tag("low")
                Text(L("Medias", "Medium")).tag("medium")
                Text(L("Altas", "High")).tag("high")
            }
            Toggle(L("Oclusión ambiental (SSAO)", "Ambient occlusion (SSAO)"), isOn: bool(\.ssao))
            Toggle(L("Bloom", "Bloom"), isOn: bool(\.bloom))
            Toggle(L("Reflejos", "Reflections"), isOn: bool(\.reflections))
        } header: {
            Text(L("Gráficos", "Graphics"))
        }
    }

    private var headsetSection: some View {
        Section {
            Toggle(L("Renderizado foveado", "Foveated rendering"), isOn: bool(\.foveation))
            LabeledContent(L("Calidad de renderizado", "Render quality")) {
                HStack {
                    Slider(value: float(\.renderQuality), in: 0.1...1, step: 0.05)
                        .frame(width: 240)
                    Text(String(format: "%.2f", model.settings.renderQuality))
                        .monospacedDigit()
                        .frame(width: 48)
                }
            }
            Toggle(L("Escalado MetalFX", "MetalFX upscaling"), isOn: bool(\.metalFX))
        } header: {
            Text(L("Visor", "Headset"))
        } footer: {
            Text(L("La calidad de renderizado es la de Compositor Services (1: los drawables más grandes que da el sistema). MetalFX escala la imagen del juego al tamaño del drawable.",
                   "Render quality is Compositor Services' (1: the largest drawables the system offers). MetalFX scales the game's picture to the drawable's size."))
        }
    }

    private var controllerSection: some View {
        Section {
            Picker(L("Giro", "Turning"), selection: int(\.turnMode)) {
                Text(L("A pasos", "Snap")).tag(0)
                Text(L("Suave", "Smooth")).tag(1)
            }
            .pickerStyle(.segmented)
            if model.settings.turnMode == 0 {
                Picker(L("Grados por paso", "Degrees per snap"), selection: int(\.snapDegrees)) {
                    Text("15°").tag(15)
                    Text("30°").tag(30)
                    Text("45°").tag(45)
                    Text("90°").tag(90)
                }
            } else {
                LabeledContent(L("Velocidad de giro", "Turning speed")) {
                    Stepper("\(model.settings.smoothSpeed) °/s", value: int(\.smoothSpeed), in: 30...240, step: 15)
                }
            }
            Picker(L("Linterna", "Flashlight"), selection: int(\.flashlightHand)) {
                Text(L("Sigue la cabeza", "Follows the head")).tag(-1)
                Text(L("Mano izquierda", "Left hand")).tag(0)
                Text(L("Mano derecha", "Right hand")).tag(1)
            }
            Toggle(L("Ver mis manos durante el juego", "See my hands while playing"), isOn: bool(\.showHands))
            Toggle(L("Pausar al quitarse el visor", "Pause when the headset is taken off"), isOn: bool(\.pauseWhenAway))
        } header: {
            Text(L("Mando y manos", "Controller and hands"))
        } footer: {
            Text(L("La linterna en una mano necesita que el visor siga esa mano o un mando PlayStation VR2 Sense; si no, sigue la cabeza.",
                   "The flashlight in a hand needs the headset to track that hand or a PlayStation VR2 Sense controller; otherwise it follows the head."))
        }
    }

    private var gameSection: some View {
        Section {
            Toggle(L("Reconocimiento de voz (radio)", "Voice recognition (radio)"), isOn: bool(\.voiceRecognition))
            Picker(L("Idioma", "Language"), selection: Binding(
                get: { AppLanguage(rawValue: model.settings.language) ?? .system },
                set: { model.setLanguage($0) })) {
                Text(L("El del sistema", "System")).tag(AppLanguage.system)
                Text("Español").tag(AppLanguage.spanish)
                Text("English").tag(AppLanguage.english)
            }
        } header: {
            Text(L("Juego", "Game"))
        } footer: {
            Text(L("El idioma es el de la app y el del juego.", "The language is the app's and the game's."))
        }
    }

    private var diagnosticsSection: some View {
        Section {
            Toggle(L("Panel de rendimiento dentro del juego", "Performance overlay in the game"), isOn: bool(\.showPerformanceOverlay))
        } header: {
            Text(L("Diagnóstico", "Diagnostics"))
        } footer: {
            Text(L("Los cambios se aplican la próxima vez que empieces el juego.", "Changes apply the next time you start the game."))
        }
    }

    // MARK: - Estimates

    private var estimatedWidth: Int {
        Int((Self.baseEyeWidth * model.settings.resolutionScale * Double(model.settings.renderQuality)).rounded())
    }

    private var estimatedHeight: Int {
        Int((Self.baseEyeHeight * model.settings.resolutionScale * Double(model.settings.renderQuality)).rounded())
    }

    // MARK: - Bindings into the model's settings

    private func bool(_ path: WritableKeyPath<PTSettings, Bool>) -> Binding<Bool> {
        Binding(get: { model.settings[keyPath: path] }, set: { model.set(path, $0) })
    }

    private func int(_ path: WritableKeyPath<PTSettings, Int>) -> Binding<Int> {
        Binding(get: { model.settings[keyPath: path] }, set: { model.set(path, $0) })
    }

    private func double(_ path: WritableKeyPath<PTSettings, Double>) -> Binding<Double> {
        Binding(get: { model.settings[keyPath: path] }, set: { model.set(path, $0) })
    }

    private func float(_ path: WritableKeyPath<PTSettings, Float>) -> Binding<Float> {
        Binding(get: { model.settings[keyPath: path] }, set: { model.set(path, $0) })
    }

    private func string(_ path: WritableKeyPath<PTSettings, String>) -> Binding<String> {
        Binding(get: { model.settings[keyPath: path] }, set: { model.set(path, $0) })
    }
}
