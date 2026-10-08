// SPDX-License-Identifier: MIT
//
// The launcher window, laid out the way visionOS apps are: a tab bar along the window's leading
// edge for its parts - the game, the settings, the performance panel and the log - with the
// game's part carrying the one prominent action. Everything else is a step away, in its own tab.

import SwiftUI
import UIKit

struct LauncherView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        TabView {
            HomeView()
                .tabItem {
                    Label(L("Jugar", "Play"), systemImage: "gamecontroller.fill")
                }
            SettingsView()
                .tabItem {
                    Label(L("Ajustes", "Settings"), systemImage: "slider.horizontal.3")
                }
            PerformanceView()
                .tabItem {
                    Label(L("Rendimiento", "Performance"), systemImage: "gauge.with.dots.needle.67percent")
                }
            LogsView()
                .tabItem {
                    Label(L("Registro", "Log"), systemImage: "doc.text.magnifyingglass")
                }
        }
        .environment(\.locale, Language.shared.locale)
        .onAppear {
            model.openLauncher = openWindow
            model.dismissImmersive = dismissImmersiveSpace
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                model.findGame()
            }
        }
    }
}

/// Green, orange or red, and the symbol that goes with it, wherever a state is shown.
enum Verdict {
    case ok, warning, missing

    var symbol: String {
        switch self {
        case .ok: "checkmark.circle.fill"
        case .warning: "exclamationmark.circle.fill"
        case .missing: "xmark.octagon.fill"
        }
    }

    var color: Color {
        switch self {
        case .ok: .green
        case .warning: .orange
        case .missing: .red
        }
    }
}

/// One of the things the game needs: what it is, whether it is there, and what to do if not.
struct StatusCard<Action: View>: View {
    let title: String
    let symbol: String
    let verdict: Verdict
    let detail: String
    @ViewBuilder let action: () -> Action

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: symbol)
                    .font(.title3)
                Spacer()
                Image(systemName: verdict.symbol)
                    .foregroundStyle(verdict.color)
                    .font(.title3)
            }
            Text(title)
                .font(.headline)
            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            action()
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
        }
        .padding(20)
        .frame(width: 250, alignment: .topLeading)
        .frame(minHeight: 160, alignment: .topLeading)
        .glassBackgroundEffect(in: .rect(cornerRadius: 28))
    }
}

/// The system's share sheet (AirDrop, Mail, Save to Files...) for the log files.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [URL]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
