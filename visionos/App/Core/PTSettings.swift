// SPDX-License-Identifier: MIT
//
// The settings, all of them changed inside the app (SettingsView) and kept in UserDefaults as
// one JSON document (key "pt.settings"). They start from a preset for the headset the app runs on
// (M2 or M5 Apple Vision Pro) and become, for the game core, the PT_VP_* environment variables
// it is started with (GameRunner).

import Foundation

struct PTSettings: Codable, Equatable {
    enum Preset: String, Codable, CaseIterable, Identifiable {
        case m2, m5, custom

        var id: String { rawValue }

        var title: String {
            switch self {
            case .m2: "M2"
            case .m5: "M5"
            case .custom: L("Personalizado", "Custom")
            }
        }
    }

    // Preset-governed (changing one of these away from the preset's value makes the preset "custom").
    var preset: Preset = .m2
    /// Each eye's picture, relative to the size the headset recommends (0.5 to 2.0).
    var resolutionScale: Double = 0.6
    /// The game draws smaller by itself while the GPU cannot keep up (off unless chosen: it
    /// trades sharpness for smoothness).
    var dynamicResolution = false
    /// 90 (every refresh) or 45 (every other one).
    var targetFPS = 90
    /// How much of the headset's field of view the game draws, in percent (70 to 100).
    var fov = 100
    /// The game's own graphics preset: low, medium, high, ultra.
    var graphicsPreset = "medium"
    /// off, low, medium, high.
    var shadows = "low"
    var ssao = false
    var bloom = true
    var reflections = false
    /// Foveated rendering (where the eyes look is drawn at the drawable's full resolution).
    var foveation = true
    /// Compositor Services' render quality with foveation (visionOS 26): 0 leaves the system's
    /// own; 0.5 to 1 asks for that much (1: the sharpest, largest drawables the system offers).
    var compositorQuality: Float = 0
    /// MetalFX upscaling of the game's picture to the drawable.
    var metalFX = false
    /// The game's own foveation: a wide low-density view of each eye and its centre on top.
    var gameFoveation = true
    /// Density of the wide view, percent of the image size (30 to 70).
    var periphery = 45
    /// Size of the sharp centre, percent of the eye's field of view across (30 to 60).
    var center = 45
    /// Sharpening of the picture on its way to the headset, 0 to 1.
    var sharpen: Double = 0.3

    // Comfort, controller and hands.
    /// 0: snap turning, 1: smooth turning.
    var turnMode = 0
    var snapDegrees = 30
    /// Degrees per second of smooth turning.
    var smoothSpeed = 90
    /// -1: the flashlight follows the head, 0: the left hand, 1: the right hand.
    var flashlightHand = -1
    /// Show the hands (and the controller in them) in front of the game.
    var showHands = false
    var pauseWhenAway = true
    /// Cutscenes drawn in stereo from the scene's camera (off: on a big virtual screen).
    var immersiveCutscenes = true

    // Game.
    var voiceRecognition = true
    /// "es", "en" or "system".
    var language = "system"

    // Diagnostics.
    var showPerformanceOverlay = false
    /// The game's data folder when it is not found by itself (empty: search Documents).
    var gamePath = ""

    // MARK: - Presets

    /// The values for a headset. The custom preset starts from the detected headset's values.
    static func defaults(for preset: Preset) -> PTSettings {
        var settings = PTSettings()
        switch preset {
        case .m2, .custom:
            settings.preset = preset
            settings.resolutionScale = 0.6
            settings.dynamicResolution = false
            // A picture every other refresh (45 at 90 Hz, 50 at 100 Hz), reprojected in between.
            settings.targetFPS = 45
            settings.fov = 100
            settings.graphicsPreset = "medium"
            settings.shadows = "high"
            settings.ssao = true
            settings.bloom = true
            settings.reflections = true
            settings.foveation = true
            settings.compositorQuality = 0
            settings.metalFX = false
        case .m5:
            settings.preset = .m5
            settings.resolutionScale = 0.85
            settings.dynamicResolution = false
            settings.targetFPS = 90
            settings.fov = 100
            settings.graphicsPreset = "high"
            settings.shadows = "high"
            settings.ssao = true
            settings.bloom = true
            settings.reflections = true
            settings.foveation = true
            settings.compositorQuality = 0
            settings.metalFX = false
        }
        return settings
    }

    /// Which headset this is: the first Apple Vision Pro (M2) is RealityDevice14,x; a later one
    /// is taken as an M5. Unknown: M2, the safer preset.
    static func detectedPreset() -> Preset {
        let model = hardwareModel()
        if model.contains("RealityDevice14") {
            return .m2
        }
        if model.contains("RealityDevice") {
            return .m5
        }
        // A headset with a great deal more memory than the first one (16 GB) is a later one.
        if ProcessInfo.processInfo.physicalMemory >= 24 * 1024 * 1024 * 1024 {
            return .m5
        }
        return .m2
    }

    /// "RealityDevice14,1" and the like, from sysctl (hw.machine, else hw.model).
    static func hardwareModel() -> String {
        for name in ["hw.machine", "hw.model"] {
            var size = 0
            guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { continue }
            var buffer = [CChar](repeating: 0, count: size + 1)
            guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { continue }
            let value = String(cString: buffer)
            if !value.isEmpty {
                return value
            }
        }
        return ""
    }

    /// Takes the preset's values, keeping the comfort, game and diagnostic settings.
    mutating func apply(preset: Preset) {
        let base = Self.defaults(for: preset == .custom ? Self.detectedPreset() : preset)
        resolutionScale = base.resolutionScale
        dynamicResolution = base.dynamicResolution
        targetFPS = base.targetFPS
        fov = base.fov
        graphicsPreset = base.graphicsPreset
        shadows = base.shadows
        ssao = base.ssao
        bloom = base.bloom
        reflections = base.reflections
        foveation = base.foveation
        compositorQuality = base.compositorQuality
        metalFX = base.metalFX
        sharpen = base.sharpen
        self.preset = preset
    }

    /// Whether the preset-governed values are still the preset's.
    private func matches(preset: Preset) -> Bool {
        let base = Self.defaults(for: preset)
        return resolutionScale == base.resolutionScale && dynamicResolution == base.dynamicResolution
            && targetFPS == base.targetFPS && fov == base.fov && graphicsPreset == base.graphicsPreset
            && shadows == base.shadows && ssao == base.ssao && bloom == base.bloom
            && reflections == base.reflections && foveation == base.foveation
            && compositorQuality == base.compositorQuality && metalFX == base.metalFX && sharpen == base.sharpen
    }

    /// Changes one setting. A preset-governed setting that leaves the preset's values makes the
    /// preset "custom"; the comfort, game and diagnostic settings do not belong to a preset.
    mutating func update<T: Equatable>(_ keyPath: WritableKeyPath<PTSettings, T>, to value: T) {
        guard self[keyPath: keyPath] != value else { return }
        self[keyPath: keyPath] = value
        if preset != .custom && !matches(preset: preset) {
            preset = .custom
        }
    }

    // MARK: - Persistence

    static let defaultsKey = "pt.settings"

    static var documents: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    /// The saved settings, or the detected headset's preset the first time.
    static func load() -> PTSettings {
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           var saved = try? JSONDecoder().decode(PTSettings.self, from: data) {
            // The M5's preset only on an M5: on another headset it falls back to the M2's.
            if saved.preset == .m5 && detectedPreset() != .m5 {
                saved.apply(preset: .m2)
            }
            // A headset preset keeps following its values when a new version changes them.
            if saved.preset != .custom {
                saved.apply(preset: saved.preset)
            }
            return saved
        }
        return defaults(for: detectedPreset())
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }

    // Every key is optional when decoding, so that settings saved by an older version still load.
    enum CodingKeys: String, CodingKey {
        case preset, resolutionScale, targetFPS, fov, graphicsPreset, shadows
        // A new key: the old one was saved as on by versions in which it did nothing.
        case dynamicResolution = "dynamicResolutionChosen"
        case ssao, bloom, reflections, foveation, compositorQuality, metalFX, sharpen, gameFoveation, periphery, center
        case turnMode, snapDegrees, smoothSpeed, flashlightHand, showHands, pauseWhenAway, immersiveCutscenes
        case voiceRecognition, language, showPerformanceOverlay, gamePath
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let base = PTSettings()
        preset = (try? c.decodeIfPresent(Preset.self, forKey: .preset)) ?? base.preset
        resolutionScale = (try? c.decodeIfPresent(Double.self, forKey: .resolutionScale)) ?? base.resolutionScale
        dynamicResolution = (try? c.decodeIfPresent(Bool.self, forKey: .dynamicResolution)) ?? base.dynamicResolution
        targetFPS = (try? c.decodeIfPresent(Int.self, forKey: .targetFPS)) ?? base.targetFPS
        fov = (try? c.decodeIfPresent(Int.self, forKey: .fov)) ?? base.fov
        graphicsPreset = (try? c.decodeIfPresent(String.self, forKey: .graphicsPreset)) ?? base.graphicsPreset
        shadows = (try? c.decodeIfPresent(String.self, forKey: .shadows)) ?? base.shadows
        ssao = (try? c.decodeIfPresent(Bool.self, forKey: .ssao)) ?? base.ssao
        bloom = (try? c.decodeIfPresent(Bool.self, forKey: .bloom)) ?? base.bloom
        reflections = (try? c.decodeIfPresent(Bool.self, forKey: .reflections)) ?? base.reflections
        foveation = (try? c.decodeIfPresent(Bool.self, forKey: .foveation)) ?? base.foveation
        compositorQuality = (try? c.decodeIfPresent(Float.self, forKey: .compositorQuality)) ?? base.compositorQuality
        metalFX = (try? c.decodeIfPresent(Bool.self, forKey: .metalFX)) ?? base.metalFX
        gameFoveation = (try? c.decodeIfPresent(Bool.self, forKey: .gameFoveation)) ?? base.gameFoveation
        periphery = (try? c.decodeIfPresent(Int.self, forKey: .periphery)) ?? base.periphery
        center = (try? c.decodeIfPresent(Int.self, forKey: .center)) ?? base.center
        sharpen = (try? c.decodeIfPresent(Double.self, forKey: .sharpen)) ?? base.sharpen
        turnMode = (try? c.decodeIfPresent(Int.self, forKey: .turnMode)) ?? base.turnMode
        snapDegrees = (try? c.decodeIfPresent(Int.self, forKey: .snapDegrees)) ?? base.snapDegrees
        smoothSpeed = (try? c.decodeIfPresent(Int.self, forKey: .smoothSpeed)) ?? base.smoothSpeed
        flashlightHand = (try? c.decodeIfPresent(Int.self, forKey: .flashlightHand)) ?? base.flashlightHand
        showHands = (try? c.decodeIfPresent(Bool.self, forKey: .showHands)) ?? base.showHands
        pauseWhenAway = (try? c.decodeIfPresent(Bool.self, forKey: .pauseWhenAway)) ?? base.pauseWhenAway
        immersiveCutscenes = (try? c.decodeIfPresent(Bool.self, forKey: .immersiveCutscenes)) ?? base.immersiveCutscenes
        voiceRecognition = (try? c.decodeIfPresent(Bool.self, forKey: .voiceRecognition)) ?? base.voiceRecognition
        language = (try? c.decodeIfPresent(String.self, forKey: .language)) ?? base.language
        showPerformanceOverlay = (try? c.decodeIfPresent(Bool.self, forKey: .showPerformanceOverlay)) ?? base.showPerformanceOverlay
        gamePath = (try? c.decodeIfPresent(String.self, forKey: .gamePath)) ?? base.gamePath
    }

    // MARK: - What the game core is given

    /// The language the game is told: the setting, or the system's when it says "system".
    var resolvedLanguage: String {
        switch language {
        case "es", "en":
            return language
        default:
            return (Locale.preferredLanguages.first ?? "en").lowercased().hasPrefix("es") ? "es" : "en"
        }
    }

    /// The PT_VP_* environment variables the core reads its settings from.
    var environment: [String] {
        func flag(_ value: Bool) -> String { value ? "1" : "0" }
        return [
            "PT_VP_PRESET=\(preset.rawValue)",
            "PT_VP_DEVICE=\(Self.detectedPreset() == .m5 ? "m5" : "m2")",
            "PT_VP_RESOLUTION_SCALE=\(String(format: "%.2f", min(max(resolutionScale, 0.5), 2.0)))",
            "PT_VP_DYNAMIC_RES=\(flag(dynamicResolution))",
            "PT_VP_TARGET_FPS=\(targetFPS)",
            "PT_VP_FOV=\(min(max(fov, 70), 100))",
            "PT_VP_GRAPHICS=\(graphicsPreset)",
            "PT_VP_SHADOWS=\(shadows)",
            "PT_VP_SSAO=\(flag(ssao))",
            "PT_VP_BLOOM=\(flag(bloom))",
            "PT_VP_REFLECTIONS=\(flag(reflections))",
            "PT_VP_FOVEATION=\(flag(foveation))",
            "PT_VP_COMPOSITOR_QUALITY=\(String(format: "%.2f", compositorQuality))",
            "PT_VP_METALFX=\(flag(metalFX))",
            "PT_VP_GAME_FOVEATION=\(flag(gameFoveation))",
            "PT_VP_PERIPHERY=\(periphery)",
            "PT_VP_CENTER=\(center)",
            "PT_VP_SHARPEN=\(String(format: "%.1f", sharpen))",
            "PT_VP_TURN=\(turnMode)",
            "PT_VP_SNAP_DEGREES=\(snapDegrees)",
            "PT_VP_SMOOTH_SPEED=\(smoothSpeed)",
            "PT_VP_FLASHLIGHT_HAND=\(flashlightHand)",
            "PT_VP_SHOW_HANDS=\(flag(showHands))",
            "PT_VP_PAUSE_AWAY=\(flag(pauseWhenAway))",
            "PT_VP_CUTSCENES=\(flag(immersiveCutscenes))",
            "PT_VP_VOICE=\(flag(voiceRecognition))",
            "PT_VP_LANGUAGE=\(resolvedLanguage)",
            "PT_VP_OVERLAY=\(flag(showPerformanceOverlay))",
        ]
    }
}
