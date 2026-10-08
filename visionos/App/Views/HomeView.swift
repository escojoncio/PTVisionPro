// SPDX-License-Identifier: MIT
//
// The game: its name, what it needs (the game's data, a controller, the headset's preset) as
// three glass cards that say what to do when something is missing, and the button that starts
// it in the immersive space.

import SwiftUI

struct HomeView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            background
            VStack(alignment: .leading, spacing: 28) {
                Spacer(minLength: 0)
                VStack(alignment: .leading, spacing: 6) {
                    Text("P.T.")
                        .font(.extraLargeTitle)
                        .fontWeight(.heavy)
                    Text(L("Teaser jugable · PlayStation 4 · en VR", "Playable Teaser · PlayStation 4 · in VR"))
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
                HStack(alignment: .top, spacing: 16) {
                    dataCard
                    controllerCard
                    headsetCard
                }
                if model.dataStatus != .ready {
                    instructions
                }
                actions
            }
            .padding(48)
        }
    }

    // MARK: - Background

    private var background: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.16, green: 0.12, blue: 0.08),
                                    Color(red: 0.03, green: 0.02, blue: 0.02)],
                           startPoint: .top, endPoint: .bottom)
            // A faint warm glow low on the left, like the corridor's lamp.
            RadialGradient(colors: [Color(red: 0.9, green: 0.6, blue: 0.3).opacity(0.25), .clear],
                           center: .init(x: 0.15, y: 0.9), startRadius: 0, endRadius: 700)
            LinearGradient(stops: [.init(color: .clear, location: 0.3),
                                   .init(color: .black.opacity(0.5), location: 0.7),
                                   .init(color: .black.opacity(0.75), location: 1.0)],
                           startPoint: .top, endPoint: .bottom)
        }
        .ignoresSafeArea()
    }

    // MARK: - What the game needs

    private var dataCard: some View {
        let verdict: Verdict
        let detail: String
        switch model.dataStatus {
        case .ready:
            verdict = .ok
            let data = model.gameData
            detail = "\(data?.folder.lastPathComponent ?? GameData.folderName) · \(GameData.format(bytes: data?.totalBytes ?? 0))"
        case .incomplete(let files):
            verdict = .warning
            detail = L("Faltan: \(files.joined(separator: ", "))", "Missing: \(files.joined(separator: ", "))")
        case .missing:
            verdict = .missing
            detail = L("Copia la carpeta \(GameData.folderName) con Archivos", "Copy the \(GameData.folderName) folder with Files")
        }
        return StatusCard(title: L("Datos del juego", "Game data"), symbol: "opticaldisc.fill", verdict: verdict, detail: detail) {
            if model.dataStatus != .ready {
                Button(L("Buscar", "Find")) {
                    model.findGame()
                }
            }
        }
    }

    private var controllerCard: some View {
        let controller = model.controller
        let verdict: Verdict = controller == nil ? .warning : (controller!.isPlayStation ? .ok : .warning)
        var detail = controller?.name ?? L("Empareja un DualSense", "Pair a DualSense")
        if let level = controller?.batteryLevel {
            detail += " · \(Int((level * 100).rounded())) %"
            if controller?.isCharging == true {
                detail += " ⚡︎"
            }
        }
        return StatusCard(title: L("Mando", "Controller"), symbol: "gamecontroller.fill", verdict: verdict, detail: detail) {
            EmptyView()
        }
    }

    private var headsetCard: some View {
        let settings = model.settings
        let detail = L("Preset \(settings.preset.title) · \(Int((settings.resolutionScale * 100).rounded())) % · \(settings.targetFPS) fps",
                       "Preset \(settings.preset.title) · \(Int((settings.resolutionScale * 100).rounded())) % · \(settings.targetFPS) fps")
        return StatusCard(title: L("Visor", "Headset"), symbol: "visionpro", verdict: .ok, detail: detail) {
            EmptyView()
        }
    }

    private var instructions: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L("Cómo poner el juego", "How to add the game"))
                .font(.headline)
            Text(L("Copia la carpeta \(GameData.folderName) de tu copia de P.T. (la que tiene chunk1.psarc y texture.qar) a «En mi Apple Vision Pro › P.T. VR» con la app Archivos, por ejemplo desde una carpeta compartida de tu PC (Archivos › Conectarse a un servidor). Vuelve aquí y pulsa Buscar.",
                   "Copy the \(GameData.folderName) folder of your copy of P.T. (the one with chunk1.psarc and texture.qar) to “On My Apple Vision Pro › P.T. VR” with the Files app, for example from a shared folder on your PC (Files › Connect to Server). Come back here and press Find."))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .frame(maxWidth: 800, alignment: .leading)
        .glassBackgroundEffect(in: .rect(cornerRadius: 24))
    }

    // MARK: - Starting

    @ViewBuilder
    private var actions: some View {
        HStack(spacing: 16) {
            if model.running {
                Button(role: .destructive) {
                    model.quitGame()
                } label: {
                    Label(L("Terminar partida", "End game"), systemImage: "stop.fill")
                        .padding(.horizontal, 12)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.extraLarge)
                .buttonBorderShape(.capsule)
            } else {
                Button {
                    open()
                } label: {
                    Label(L("Jugar en VR", "Play in VR"), systemImage: "play.fill")
                        .padding(.horizontal, 24)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.extraLarge)
                .buttonBorderShape(.capsule)
                .disabled(!model.canStart)
            }
            if let message = model.message {
                Text(message)
                    .font(.callout)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .glassBackgroundEffect(in: .capsule)
            } else if !model.canStart && !model.running {
                Text(model.startHint)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func open() {
        LogFiles.log("Opening the immersive space")
        Task {
            switch await openImmersiveSpace(id: AppModel.immersiveSpaceID) {
            case .opened:
                model.immersiveOpened()
                // Only the game in view: the launcher comes back when the game ends.
                dismissWindow(id: AppModel.launcherID)
            default:
                model.message = L("No se pudo abrir el espacio inmersivo.", "The immersive space could not be opened.")
            }
        }
    }
}
