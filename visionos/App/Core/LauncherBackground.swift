// SPDX-License-Identifier: MIT
//
// The launcher's background picture. Nothing of the game ships in the app, so the picture comes
// from the player: one they choose (from Photos or Files), kept inside the app on the headset;
// failing that, the cover art in their own copy of the game (sce_sys/pic1.png or pic0.png);
// failing that, the plain gradient.

import Foundation
import Observation
import UIKit

@MainActor
@Observable
final class LauncherBackground {
    static let shared = LauncherBackground()

    /// The picture shown, if any.
    private(set) var image: UIImage?
    /// The picture is the player's own choice (it can be removed).
    private(set) var isChosen = false

    private var gameFolder: URL?

    private static var fileURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("launcher-background.jpg")
    }

    private init() {
        reload()
    }

    /// The game's folder changed (found, lost): its cover art is the fallback.
    func setGameFolder(_ folder: URL?) {
        guard folder != gameFolder else { return }
        gameFolder = folder
        reload()
    }

    /// The picture's bytes, as Photos or Files give them: scaled down and kept in the app.
    @discardableResult
    func choose(_ data: Data) -> Bool {
        guard let picked = UIImage(data: data) else {
            LogFiles.log("Background: not a picture (\(data.count) bytes)")
            return false
        }
        let scaled = Self.scaled(picked, longest: 2400)
        guard let jpeg = scaled.jpegData(compressionQuality: 0.85) else { return false }
        do {
            try FileManager.default.createDirectory(at: Self.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try jpeg.write(to: Self.fileURL, options: .atomic)
        } catch {
            LogFiles.log("Background: cannot save (\(error.localizedDescription))")
            return false
        }
        LogFiles.log("Background: chosen, \(Int(scaled.size.width))x\(Int(scaled.size.height))")
        reload()
        return true
    }

    func clear() {
        try? FileManager.default.removeItem(at: Self.fileURL)
        LogFiles.log("Background: removed")
        reload()
    }

    private func reload() {
        if let data = try? Data(contentsOf: Self.fileURL), let chosen = UIImage(data: data) {
            image = chosen
            isChosen = true
            return
        }
        isChosen = false
        image = nil
        if let folder = gameFolder {
            for name in ["pic1.png", "pic0.png"] {
                let url = folder.appendingPathComponent("sce_sys").appendingPathComponent(name)
                if let data = try? Data(contentsOf: url), let art = UIImage(data: data) {
                    image = art
                    return
                }
            }
        }
    }

    private static func scaled(_ image: UIImage, longest: CGFloat) -> UIImage {
        let size = image.size
        let factor = min(1.0, longest / max(size.width, size.height, 1.0))
        if factor >= 1.0 { return image }
        let target = CGSize(width: (size.width * factor).rounded(), height: (size.height * factor).rounded())
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
    }
}
