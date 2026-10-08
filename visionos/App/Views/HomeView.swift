// SPDX-License-Identifier: MIT
//
// The game: its name, what it needs (the game's data, a controller, the headset's preset) as
// three glass cards that say what to do when something is missing, and the button that starts
// it in the immersive space.

import Foundation
import SwiftUI
import UniformTypeIdentifiers

struct HomeView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var choosingVPS4 = false

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            background
            VStack(alignment: .leading, spacing: 28) {
                Spacer(minLength: 0)
                VStack(alignment: .leading, spacing: 6) {
                    if LauncherBackground.shared.image == nil {
                        // (A background picture usually carries the title already.)
                        Text("P.T.")
                            .font(.extraLargeTitle)
                            .fontWeight(.heavy)
                    }
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
        .fileImporter(isPresented: $choosingVPS4, allowedContentTypes: [.folder]) { result in
            switch result {
            case .success(let url):
                if let problem = VPS4Folder.shared.choose(url) {
                    model.message = problem
                } else {
                    model.message = nil
                }
                model.findGame()
            case .failure(let error):
                LogFiles.log("VPS4: picker failed (\(error.localizedDescription))")
            }
        }
    }

    // MARK: - Background

    private var background: some View {
        ZStack {
            if let picture = LauncherBackground.shared.image {
                // The player's picture (or their game's cover art), darkened low down so that the
                // title and the cards stay readable over it.
                GeometryReader { geometry in
                    Image(uiImage: picture)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .clipped()
                }
                LinearGradient(stops: [.init(color: .black.opacity(0.15), location: 0.0),
                                       .init(color: .black.opacity(0.45), location: 0.45),
                                       .init(color: .black.opacity(0.85), location: 1.0)],
                               startPoint: .top, endPoint: .bottom)
            } else {
                gradient
            }
        }
        .ignoresSafeArea()
    }

    private var gradient: some View {
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
        let hasVPS4 = VPS4Folder.shared.url != nil
        switch model.dataStatus {
        case .ready:
            let data = model.gameData
            let place = data?.inVPS4 == true ? "VPS4 › \(VPS4Folder.gamesName) › " : ""
            let name = "\(place)\(data?.folder.lastPathComponent ?? GameData.folderName) · \(GameData.format(bytes: data?.totalBytes ?? 0))"
            if let odd = data?.unexpectedSize, !odd.isEmpty {
                verdict = .warning
                detail = name + "\n" + L("No es la versión US v01.00 (tamaño distinto: \(odd.joined(separator: ", "))); puede no funcionar.",
                                         "Not the US v01.00 release (different size: \(odd.joined(separator: ", "))); it may not work.")
            } else {
                verdict = .ok
                detail = name
            }
        case .incomplete(let files):
            verdict = .warning
            detail = L("Faltan: \(files.joined(separator: ", "))", "Missing: \(files.joined(separator: ", "))")
        case .missing:
            verdict = .missing
            detail = hasVPS4
                ? L("Copia \(GameData.folderName) a VPS4 › \(VPS4Folder.gamesName)", "Copy \(GameData.folderName) to VPS4 › \(VPS4Folder.gamesName)")
                : L("Elige tu carpeta VPS4", "Choose your VPS4 folder")
        }
        return StatusCard(title: L("Datos del juego", "Game data"), symbol: "opticaldisc.fill", verdict: verdict, detail: detail) {
            HStack(spacing: 8) {
                if !hasVPS4 {
                    Button(L("Elegir VPS4", "Choose VPS4")) {
                        choosingVPS4 = true
                    }
                } else if model.dataStatus != .ready {
                    Button(L("Buscar", "Find")) {
                        model.findGame()
                    }
                }
            }
        }
    }

    private var controllerCard: some View {
        let controller = model.controller
        let verdict: Verdict = controller == nil ? .warning : .ok
        var detail = controller?.name ?? L("Empareja un mando (o usa las manos en los menús)", "Pair a controller (or use your hands in menus)")
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
            Text(L("""
                   1. En la app Archivos, en «En mi Apple Vision Pro», crea una carpeta llamada VPS4 (si ya la tienes de ASTRO BOT, sirve la misma).
                   2. Pulsa «Elegir VPS4» y elige esa carpeta. La app crea dentro las carpetas \(VPS4Folder.gamesName) y \(VPS4Folder.savesName) (ahí van las partidas).
                   3. Copia la carpeta \(GameData.folderName) de tu copia de P.T. (la que tiene chunk1.psarc y texture.qar) a VPS4 › \(VPS4Folder.gamesName), por ejemplo desde una carpeta compartida de tu PC (Archivos › Conectarse a un servidor), y pulsa «Buscar».
                   """,
                   """
                   1. In the Files app, under “On My Apple Vision Pro”, make a folder called VPS4 (if you already have it from ASTRO BOT, the same one works).
                   2. Press “Choose VPS4” and pick that folder. The app makes the \(VPS4Folder.gamesName) and \(VPS4Folder.savesName) folders in it (saves go there).
                   3. Copy the \(GameData.folderName) folder of your copy of P.T. (the one with chunk1.psarc and texture.qar) to VPS4 › \(VPS4Folder.gamesName), for example from a shared folder on your PC (Files › Connect to Server), and press “Find”.
                   """))
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
                if model.canContinue {
                    Button {
                        open()
                    } label: {
                        Label(L("Continuar en VR", "Continue in VR"), systemImage: "play.fill")
                            .padding(.horizontal, 24)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.extraLarge)
                    .buttonBorderShape(.capsule)
                }
                Button(role: .destructive) {
                    model.quitGame()
                } label: {
                    Label(L("Terminar partida", "End game"), systemImage: "stop.fill")
                        .padding(.horizontal, 12)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.extraLarge)
                .buttonBorderShape(.capsule)
            } else if model.needsRelaunch {
                // The game core starts once per process: playing again takes a fresh start.
                Button {
                    LogFiles.log("Closing the app to play again")
                    exit(0)
                } label: {
                    Label(L("Cerrar la app", "Close the app"), systemImage: "arrow.clockwise")
                        .padding(.horizontal, 24)
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
