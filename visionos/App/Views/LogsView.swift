// SPDX-License-Identifier: MIT
//
// The log: the last lines of the core's log (pt_vp_log_path), refreshed while the game runs,
// and the files to send.

import Combine
import SwiftUI

struct LogsView: View {
    @Environment(AppModel.self) private var model
    @State private var text = ""
    @State private var source = ""
    @State private var shareFiles: [URL]?

    private let refresh = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(source.isEmpty ? L("El registro del juego aparece cuando el juego arranca.", "The game's log appears once the game starts.") : source)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button {
                        reload()
                    } label: {
                        Label(L("Actualizar", "Refresh"), systemImage: "arrow.clockwise")
                    }
                    Button {
                        shareFiles = LogFiles.filesToShare()
                    } label: {
                        Label(L("Compartir", "Share"), systemImage: "square.and.arrow.up")
                    }
                    .disabled(LogFiles.filesToShare().isEmpty)
                }
                ScrollViewReader { proxy in
                    ScrollView {
                        Text(text.isEmpty ? L("(vacío)", "(empty)") : text)
                            .font(.system(.caption, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                            .padding(12)
                        Color.clear
                            .frame(height: 1)
                            .id("end")
                    }
                    .background(.black.opacity(0.25), in: .rect(cornerRadius: 16))
                    .onChange(of: text) { _, _ in
                        proxy.scrollTo("end", anchor: .bottom)
                    }
                }
                Text(L("Archivos › En mi Apple Vision Pro › P.T. VR › Registros", "Files › On My Apple Vision Pro › P.T. VR › Registros"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(24)
            .navigationTitle(L("Registro", "Log"))
        }
        .onAppear(perform: reload)
        .onReceive(refresh) { _ in
            if model.running {
                reload()
            }
        }
        .sheet(isPresented: Binding(get: { shareFiles != nil }, set: { if !$0 { shareFiles = nil } })) {
            ShareSheet(items: shareFiles ?? [])
        }
    }

    private func reload() {
        if let core = LogFiles.coreLogURL {
            source = core.path
            text = LogFiles.tail(of: core)
        } else {
            source = ""
            text = LogFiles.tail(of: LogFiles.appLogURL)
        }
    }
}
