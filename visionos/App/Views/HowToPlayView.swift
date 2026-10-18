// SPDX-License-Identifier: MIT
//
// A short, spoiler-free guide to playing in the headset: how to move, look, interact, use the
// menus, and where the comfort options are. Only what the port really does; nothing about the
// game itself.

import SwiftUI

struct HowToPlayView: View {
    private struct Item: Identifiable {
        let id: Int
        let symbol: String
        let title: String
        let lines: [String]
    }

    private var items: [Item] {
        [
            Item(id: 0, symbol: "figure.walk",
                 title: L("Moverte y mirar", "Moving and looking"),
                 lines: [
                    L("Stick izquierdo: caminar.", "Left stick: walk."),
                    L("Stick derecho: girar. Puede ser a saltos o suave; se cambia en la página VR de los ajustes del juego.",
                      "Right stick: turn. It can be snap or smooth; change it on the VR page of the game's settings."),
                    L("Mira alrededor con la cabeza. Puedes inclinarte un poco en tu sitio, pero para avanzar usa el stick.",
                      "Look around with your head. You can lean a little where you stand, but you move with the stick."),
                    L("La linterna sigue a tu cabeza: ilumina hacia donde miras.",
                      "The flashlight follows your head: it lights where you look."),
                 ]),
            Item(id: 1, symbol: "hand.point.up.left.fill",
                 title: L("Interactuar y mirar de cerca", "Interacting and looking closely"),
                 lines: [
                    L("X (cruz): interactuar con lo que tienes delante.", "X (cross): interact with what is in front of you."),
                    L("Para mirar algo de cerca, mantén X mientras lo miras.", "To look at something closely, hold X while you look at it."),
                    L("Círculo: volver atrás o cancelar.", "Circle: go back or cancel."),
                    L("Cuadrado y triángulo: el juego los pide en momentos concretos; sigue lo que indique la pantalla.",
                      "Square and triangle: the game asks for them at certain moments; follow what the screen shows."),
                    L("OPTIONS: menú de pausa.", "OPTIONS: pause menu."),
                 ]),
            Item(id: 2, symbol: "mic.fill",
                 title: L("Voz", "Voice"),
                 lines: [
                    L("A veces el juego escucha tu voz por el micrófono.", "Sometimes the game listens to your voice through the microphone."),
                    L("Cuando el juego esté escuchando, di la palabra que espera o pulsa L2 + R2 a la vez.",
                      "When the game is listening, say the word it expects, or press L2 + R2 together."),
                 ]),
            Item(id: 3, symbol: "slider.horizontal.3",
                 title: L("Menús y ajustes", "Menus and settings"),
                 lines: [
                    L("Los menús se manejan con el mando, o con las manos: apunta y pellizca (mira y pellizca).",
                      "Menus work with a controller, or with your hands: point and pinch (look and pinch)."),
                    L("Recentrar: mantén pulsada la Digital Crown, o usa la fila Recentrar vista en los ajustes VR del juego.",
                      "Recentre: long press the Digital Crown, or use the Recentre view row in the game's VR settings."),
                    L("El tamaño y la altura de los subtítulos, y las opciones de comodidad, están en la página VR de los ajustes del juego.",
                      "Subtitle size and height, and the comfort options, are on the VR page of the game's settings."),
                 ]),
            Item(id: 4, symbol: "lightbulb.fill",
                 title: L("Consejos sin spoilers", "Tips, no spoilers"),
                 lines: [
                    L("Tómate tu tiempo y no tengas prisa.", "Take your time; there is no rush."),
                    L("Escucha con atención: el sonido cuenta mucho.", "Listen carefully: sound matters a lot."),
                    L("Mira bien a tu alrededor, también de cerca.", "Look around carefully, up close too."),
                    L("El juego guarda en puntos de control.", "The game saves at checkpoints."),
                    L("Si te mareas, prueba los ajustes de comodidad (giro a saltos, por ejemplo) y descansa.",
                      "If you feel dizzy, try the comfort settings (snap turning, for example) and take a break."),
                 ]),
        ]
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    ForEach(items) { item in
                        card(item)
                    }
                }
                .frame(maxWidth: 800, alignment: .leading)
                .padding(.horizontal, 24)
                .padding(.vertical, 20)
                .frame(maxWidth: .infinity)
            }
            .navigationTitle(L("Cómo jugar", "How to play"))
        }
    }

    private func card(_ item: Item) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(item.title, systemImage: item.symbol)
                .font(.title3.weight(.semibold))
            ForEach(Array(item.lines.enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassBackgroundEffect(in: .rect(cornerRadius: 24))
    }
}
