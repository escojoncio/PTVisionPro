// SPDX-License-Identifier: MIT
//
// What the launcher shows and does: the settings, the game's data, the controller, the game
// while it runs (its statistics) and the messages.

import Foundation
import Observation
import SwiftUI

/// The core's statistics, copied for the performance panel.
struct GameStats: Equatable {
    var fps = 0.0
    var frameMs = 0.0
    var gpuMs = 0.0
    var eyeWidth: UInt32 = 0
    var eyeHeight: UInt32 = 0
    var frames: UInt64 = 0
    var phase = ""
}

@MainActor
@Observable
final class AppModel {
    /// First of all: this session's app log (LogFiles.swift), so that everything after is in it.
    private let logsStarted: Bool = {
        LogFiles.begin()
        return true
    }()

    static let launcherID = "launcher"
    static let immersiveSpaceID = "game"

    var settings: PTSettings {
        didSet {
            settings.save()
        }
    }
    let detectedPreset = PTSettings.detectedPreset()
    let hardwareModel = PTSettings.hardwareModel()

    var gameData: GameData?
    var dataStatus: DataStatus = .missing
    var controller: PlayStationController.Status?
    /// The game thread is alive.
    var running = false
    /// The core was started in this process (it can be started once per process).
    var started = false
    var stats = GameStats()
    var message: String?
    var immersiveOpen = false
    /// Opens the launcher window again (it is closed while the game is shown, so that nothing
    /// but the game is in view) and closes the game's space. Kept from the launcher's environment.
    var openLauncher: OpenWindowAction?
    var dismissImmersive: DismissImmersiveSpaceAction?

    init() {
        settings = PTSettings.load()
        Language.shared.choice = AppLanguage(rawValue: settings.language) ?? .system
        LogFiles.log("Settings: \(settings.environment.joined(separator: " "))")
        findGame()
        let controllers = PlayStationController.shared
        controllers.onStatusChange = { [weak self] status in
            Task { @MainActor in
                self?.controller = status
            }
        }
        controllers.start()
        controller = controllers.status
    }

    /// The game's data folder: the gamePath setting, Documents, Documents/CUSA01127 or a folder
    /// one level below Documents (GameData.find).
    func findGame() {
        gameData = GameData.find(settingPath: settings.gamePath)
        dataStatus = gameData?.status ?? .missing
        if let gameData {
            LogFiles.log("Game data: \(gameData.folder.path), \(GameData.format(bytes: gameData.totalBytes)), "
                         + "missing \(gameData.missingRequired + gameData.missingOptional)")
        } else {
            LogFiles.log("Game data: not found")
        }
    }

    var canStart: Bool {
        dataStatus == .ready && !started
    }

    /// Why the game cannot start, for the launcher.
    var startHint: String {
        if started && !running {
            return L("Para volver a jugar, cierra la app del todo y ábrela de nuevo.",
                     "To play again, close the app completely and open it again.")
        }
        switch dataStatus {
        case .missing:
            return L("Faltan los datos del juego.", "The game's data is missing.")
        case .incomplete(let files):
            return L("Faltan ficheros: \(files.joined(separator: ", ")).", "Missing files: \(files.joined(separator: ", ")).")
        case .ready:
            return ""
        }
    }

    // MARK: - The game's space

    func immersiveOpened() {
        immersiveOpen = true
        message = nil
        LogFiles.log("Immersive space opened")
    }

    /// The core started (GameRunner, from the space's layer).
    func gameStarted() {
        started = true
        running = true
    }

    /// The game thread ended (the player closed the space, the game ended, or it failed).
    func gameEnded() {
        guard running || immersiveOpen else { return }
        running = false
        LogFiles.log("Game ended")
        if immersiveOpen {
            immersiveOpen = false
            Task { [dismissImmersive] in
                await dismissImmersive?()
            }
        }
        openLauncher?(id: Self.launcherID)
    }

    /// The game's space has closed (Digital Crown, or the system): the core is told to end.
    func immersiveEnded() {
        LogFiles.log("Immersive space closed")
        immersiveOpen = false
        if running {
            pt_vp_request_quit()
        }
        openLauncher?(id: Self.launcherID)
    }

    /// The launcher's "end game" button.
    func quitGame() {
        LogFiles.log("Quit requested")
        pt_vp_request_quit()
        if immersiveOpen {
            immersiveOpen = false
            Task { [dismissImmersive] in
                await dismissImmersive?()
            }
        }
    }

    /// Changes one setting (PTSettings.update: a preset-governed change makes the preset custom).
    func set<T: Equatable>(_ keyPath: WritableKeyPath<PTSettings, T>, _ value: T) {
        settings.update(keyPath, to: value)
    }

    func apply(preset: PTSettings.Preset) {
        settings.apply(preset: preset)
    }

    func setLanguage(_ language: AppLanguage) {
        settings.language = language.rawValue
        Language.shared.choice = language
    }
}
