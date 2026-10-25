// SPDX-License-Identifier: MIT
//
// Every setting, changed in place (there is nothing to edit in a file). Each change goes to
// PTSettings in UserDefaults through the model; a game started afterwards uses them.

import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

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
                foveationSection
                controllerSection
                gameSection
                BackgroundSection()
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
                // Only on an M5: its image size is too much for the first headset.
                if model.detectedPreset == .m5 {
                    Text("M5").tag(PTSettings.Preset.m5)
                }
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
            Text(L("M2 es el primer Apple Vision Pro; M5 el posterior (su preset solo se ofrece en un M5). Al cambiar un ajuste de imagen, gráficos o visor, el preset pasa a Personalizado.",
                   "M2 is the first Apple Vision Pro; M5 the later one (its preset is offered on an M5 only). Changing a picture, graphics or headset setting makes the preset Custom."))
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
            Picker(L("Imágenes por segundo", "Frames per second"), selection: int(\.targetFPS)) {
                Text(L("90 reales", "90 real")).tag(90)
                Text(L("45 reproyectados a 90", "45 reprojected to 90")).tag(45)
            }
            Toggle(L("Profundidad para la reproyección", "Depth for reprojection"), isOn: bool(\.sceneDepth))
            Toggle(L("Luces por teselas", "Tiled lights"), isOn: bool(\.tiledLights))
            Toggle(L("Resolución dinámica", "Dynamic resolution"), isOn: bool(\.dynamicResolution))
            LabeledContent(L("Campo de visión dibujado", "Drawn field of view")) {
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
            Text(L("La escala es relativa a la resolución que recomienda el visor. La frecuencia de la pantalla la elige visionOS (normalmente 90 Hz; 96 o 100 según las condiciones, 120 en M5): «45 reproyectados» da la mitad, 45 a 90 Hz o 50 a 100 Hz: el juego dibuja una de cada dos y el visor crea la intermedia con el movimiento de tu cabeza. Con la profundidad, lo cercano y lo lejano se desplazan bien al mover la cabeza; caminar con el stick y las animaciones siguen a 45. La resolución dinámica dibuja más pequeño mientras la GPU no llega: más fluido, menos nítido.",
                   "The scale is relative to the resolution the headset recommends. visionOS chooses the display's rate (usually 90 Hz; 96 or 100 depending on conditions, 120 on M5): “45 reprojected” gives half of it, 45 at 90 Hz or 50 at 100 Hz: the game draws every other one and the headset makes the one in between from your head's movement. With depth, near and far things shift correctly as you move your head; walking with the stick and animations stay at 45. Dynamic resolution draws smaller while the GPU cannot keep up: smoother, less sharp."))
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
            Picker(L("Filtrado anisotrópico", "Anisotropic filtering"), selection: int(\.anisotropy)) {
                Text(L("No (trilineal)", "Off (trilinear)")).tag(0)
                Text("2x").tag(2)
                Text("4x").tag(4)
                Text("8x").tag(8)
                Text("16x").tag(16)
            }
            Picker(L("HDR (brillo máximo)", "HDR (peak brightness)"), selection: int(\.hdr)) {
                Text(L("No", "Off")).tag(100)
                Text("1,4×").tag(140)
                Text("1,7×").tag(170)
                Text(L("2× (máximo del visor)", "2× (the headset's most)")).tag(200)
            }
        } header: {
            Text(L("Gráficos", "Graphics"))
        }
    }

    private var headsetSection: some View {
        Section {
            Toggle(L("Foveado del visor (Apple)", "Headset foveation (Apple)"), isOn: bool(\.foveation))
            Picker(L("Calidad del visor", "Headset render quality"), selection: float(\.compositorQuality)) {
                Text(L("La del sistema", "System")).tag(Float(0))
                Text("60 %").tag(Float(0.6))
                Text("70 %").tag(Float(0.7))
                Text("80 %").tag(Float(0.8))
                Text("90 %").tag(Float(0.9))
                Text("100 %").tag(Float(1.0))
            }
            .disabled(!model.settings.foveation)
        } header: {
            Text(L("Visor", "Headset"))
        } footer: {
            Text(L("Foveado del visor (Apple): lo hace el propio visor al componer la imagen final; no cambia lo que dibuja el juego. Calidad del visor: resolución de las imágenes que compone el visor.",
                   "Headset foveation (Apple): done by the headset itself when it composes the final picture; it does not change what the game draws. Headset render quality: resolution of the pictures the headset composes."))
        }
    }

    private var foveationSection: some View {
        Section {
            Toggle(L("Foveado del juego", "Game foveation"), isOn: bool(\.gameFoveation))
            LabeledContent(L("Ancho de la zona nítida", "Sharp zone width")) {
                Stepper("\(model.settings.center)°", value: int(\.center), in: 20...70, step: 5)
            }
            .disabled(!model.settings.gameFoveation)
            LabeledContent(L("Altura de la zona nítida", "Sharp zone height")) {
                Stepper("\(model.settings.centerUp > 0 ? "+" : "")\(model.settings.centerUp)°", value: int(\.centerUp), in: -20...10, step: 2)
            }
            .disabled(!model.settings.gameFoveation)
            LabeledContent(L("Nitidez de la zona nítida", "Sharp zone resolution")) {
                Stepper("\(model.settings.centerResolution) %", value: int(\.centerResolution), in: 50...100, step: 5)
            }
            .disabled(!model.settings.gameFoveation)
            LabeledContent(L("Nitidez de la periferia", "Periphery resolution")) {
                Stepper("\(model.settings.periphery) %", value: int(\.periphery), in: 10...50, step: 5)
            }
            .disabled(!model.settings.gameFoveation)
            Picker(L("Antialiasing de la zona nítida", "Sharp zone antialiasing"), selection: int(\.aa)) {
                Text(L("VPKTAA (temporal)", "VPKTAA (temporal)")).tag(5)
                Text(L("FXAA (básico, para comparar)", "FXAA (basic, to compare)")).tag(0)
            }
            Picker(L("Resolución interna de VPKTAA", "VPKTAA internal resolution"), selection: int(\.taaRes)) {
                ForEach([100, 90, 85, 80], id: \.self) { percent in
                    Text("\(percent) %").tag(percent)
                }
            }
            .disabled(model.settings.aa != 5)
            Picker(L("Nitidez de VPKTAA", "VPKTAA sharpness"), selection: int(\.taaSharpness)) {
                ForEach(Array(stride(from: 0, through: 100, by: 10)), id: \.self) { percent in
                    Text("\(percent) %").tag(percent)
                }
            }
            .disabled(model.settings.aa != 5)
            Toggle(L("VPKTAA también en la periferia", "VPKTAA also in the periphery"), isOn: bool(\.taaPeriphery))
                .disabled(model.settings.aa != 5)
            Toggle(L("AA especular", "Specular AA"), isOn: bool(\.specularAA))
        } header: {
            Text(L("Foveado del juego", "Game foveation"))
        } footer: {
            Text(L("Solo un círculo en el centro de la vista se dibuja nítido; todo lo de fuera, a baja resolución. Ancho: diámetro del círculo en grados (40° es más o menos lo que miras de frente; más ancho cuesta mucho más). Altura: súbelo (+) o bájalo (-) hasta que lo borroso de arriba y de abajo te parezca igual. Nitidez de la zona y de la periferia: resolución respecto al tamaño de imagen, independientes entre sí. En el menú del juego puedes mostrar un aro rojo donde acaba la zona. Antialiasing: VPKTAA dibuja la zona con un desplazamiento diminuto en cada fotograma y combina varios: bordes limpios y mucho menos parpadeo, con afilado. FXAA difumina los bordes de cada fotograma (más blando; se deja para comparar). Solo con VPKTAA: resolución interna (100 %: la zona a tamaño completo, solo suaviza bordes, lo más nítido; 90/85/80 %: la zona se dibuja más pequeña y VPKTAA la reconstruye con los fotogramas anteriores: más fps, algo menos de detalle) nitidez (cuánto se afila la imagen; 0 % nada, muy alta puede dejar un contorno claro en los bordes) y periferia (la parte borrosa fuera del círculo también lleva VPKTAA: no añade detalle, pero evita que los bordes parpadeen por el rabillo del ojo; cuesta muy poco).",
                   "Only a circle in the middle of the view is drawn sharp; everything outside it at a low resolution. Width: the circle's diameter in degrees (40° is about what you look at straight ahead; wider costs much more). Height: move it up (+) or down (-) until the blur above and below look the same. Zone and periphery resolution: relative to the image size, independent of each other. The game's menu can show a red ring where the zone ends. Antialiasing: VPKTAA draws the zone with a tiny shift each frame and combines several frames: clean edges and much less shimmer, sharpened. FXAA blurs each frame's edges (softer; kept to compare). Only with VPKTAA: internal resolution (100 %: the zone at full size, it only smooths the edges, the sharpest; 90/85/80 %: the zone is drawn smaller and VPKTAA rebuilds it from the past frames: more frames per second, a little less detail) sharpness (how much the picture is sharpened; 0 % none, very high can leave a bright outline around edges) and periphery (the blurry part outside the circle gets VPKTAA too: no added detail, but edges stop flickering at the side of your vision; costs very little)."))
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
                    Text("60°").tag(60)
                    Text("90°").tag(90)
                }
            } else {
                LabeledContent(L("Velocidad de giro", "Turning speed")) {
                    Stepper("\(model.settings.smoothSpeed) °/s", value: int(\.smoothSpeed), in: 30...240, step: 15)
                }
            }
            Toggle(L("Ver mis manos durante el juego", "See my hands while playing"), isOn: bool(\.showHands))
            Toggle(L("Pausar al quitarse el visor", "Pause when the headset is taken off"), isOn: bool(\.pauseWhenAway))
        } header: {
            Text(L("Mando y manos", "Controller and hands"))
        } footer: {
            Text(L("La linterna sigue la cabeza. En VR, X sirve también de zoom (R3): mira al punto y pulsa o mantén X.",
                   "The flashlight follows the head. In VR, X also works as the zoom (R3): look at the spot and press or hold X."))
        }
    }

    private var gameSection: some View {
        Section {
            Toggle(L("Reconocimiento de voz (radio)", "Voice recognition (radio)"), isOn: bool(\.voiceRecognition))
            Toggle(L("Escenas inmersivas", "Immersive cutscenes"), isOn: bool(\.immersiveCutscenes))
            LabeledContent(L("Tamaño de los subtítulos", "Subtitle size")) {
                Stepper("\(model.settings.subtitleSize) %", value: int(\.subtitleSize), in: 100...250, step: 25)
            }
            LabeledContent(L("Altura de los subtítulos", "Subtitle height")) {
                Stepper("\(model.settings.subtitleHeight) %", value: int(\.subtitleHeight), in: 0...40, step: 5)
            }
            Picker(L("Idioma", "Language"), selection: Binding(
                get: { AppLanguage(rawValue: model.settings.language) ?? .system },
                set: { model.setLanguage($0) })) {
                Text(L("El del sistema", "System")).tag(AppLanguage.system)
                Text("Español").tag(AppLanguage.spanish)
                Text("English").tag(AppLanguage.english)
            }
            Picker(L("Idioma del juego (subtítulos)", "Game language (subtitles)"), selection: string(\.gameLanguage)) {
                Text(L("Como la app", "Same as the app")).tag("app")
                Text(L("English (sin subtítulos)", "English (no subtitles)")).tag("off")
                Text("English").tag("0")
                Text("Français").tag("1")
                Text("Deutsch").tag("2")
                Text("Español").tag("3")
                Text("日本語").tag("4")
                Text("Italiano").tag("5")
                Text("Português").tag("6")
                Text("Türkçe").tag("7")
                Text("简体中文").tag("8")
                Text("العربية").tag("9")
                Text("Русский").tag("10")
                Text("Українська").tag("11")
                Text("Čeština").tag("12")
                Text("Polski").tag("13")
            }
        } header: {
            Text(L("Juego", "Game"))
        } footer: {
            Text(L("Idioma: el de la app es el de los menús del launcher; el del juego (subtítulos) puede ser otro y se impone a lo guardado en la partida al empezar. Escenas inmersivas: las escenas se ven en 3D desde su cámara, con la cabeza libre; sin ellas, en una pantalla virtual. Se aplica al empezar la partida.",
                   "Language: the app's is the launcher's menus; the game's (subtitles) can differ and overrides what the save stored when the game starts. Immersive cutscenes: scenes are shown in 3D from their camera, with the head free; without them, on a virtual screen. Applies when the game starts."))
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
        Int((Self.baseEyeWidth * model.settings.resolutionScale).rounded())
    }

    private var estimatedHeight: Int {
        Int((Self.baseEyeHeight * model.settings.resolutionScale).rounded())
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

/// The launcher's background picture: from Photos or Files, kept in the app on the headset.
struct BackgroundSection: View {
    @State private var photo: PhotosPickerItem?
    @State private var choosingFile = false
    @State private var problem: String?

    var body: some View {
        let background = LauncherBackground.shared
        Section {
            HStack(spacing: 16) {
                if let picture = background.image {
                    Image(uiImage: picture)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 160, height: 90)
                        .clipShape(.rect(cornerRadius: 12))
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(background.isChosen ? L("Imagen elegida", "Chosen picture")
                         : background.image != nil ? L("Portada de tu copia del juego", "Your game copy's cover art")
                         : L("Sin imagen (degradado)", "No picture (gradient)"))
                    if let problem {
                        Text(problem)
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            }
            PhotosPicker(selection: $photo, matching: .images) {
                Label(L("Elegir de Fotos", "Choose from Photos"), systemImage: "photo.on.rectangle")
            }
            Button {
                choosingFile = true
            } label: {
                Label(L("Elegir de Archivos", "Choose from Files"), systemImage: "folder")
            }
            if background.isChosen {
                Button(role: .destructive) {
                    background.clear()
                } label: {
                    Label(L("Quitar imagen", "Remove picture"), systemImage: "trash")
                }
            }
        } header: {
            Text(L("Fondo del menú", "Menu background"))
        } footer: {
            Text(L("La imagen se guarda solo en este visor, dentro de la app.", "The picture is kept on this headset only, inside the app."))
        }
        .onChange(of: photo) { _, item in
            guard let item else { return }
            Task {
                let data = try? await item.loadTransferable(type: Data.self)
                problem = data.map { LauncherBackground.shared.choose($0) } == true
                    ? nil : L("No se pudo usar esa imagen.", "That picture could not be used.")
                photo = nil
            }
        }
        .fileImporter(isPresented: $choosingFile, allowedContentTypes: [.image]) { result in
            guard case .success(let url) = result else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer {
                if scoped { url.stopAccessingSecurityScopedResource() }
            }
            let data = try? Data(contentsOf: url)
            problem = data.map { LauncherBackground.shared.choose($0) } == true
                ? nil : L("No se pudo usar esa imagen.", "That picture could not be used.")
        }
    }
}
