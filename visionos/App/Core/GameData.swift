// SPDX-License-Identifier: MIT
//
// The game's data: the CUSA01127 folder of the PlayStation 4 release, copied into the app's
// Documents with the Files app. What the core needs of it is chunk1.psarc (the game's files)
// and texture.qar (its textures); param.sfo and pathid_list_ps4.bin are good to have.

import Foundation

enum DataStatus: Equatable {
    /// No folder with any of the game's files was found.
    case missing
    /// A folder was found but some of the required files are not in it.
    case incomplete(missingFiles: [String])
    case ready
}

struct GameData {
    static let requiredFiles = ["chunk1.psarc", "texture.qar"]
    static let optionalFiles = ["sce_sys/param.sfo", "pathid_list_ps4.bin"]
    /// The folder's name on the console, the name the player is told to copy.
    static let folderName = "CUSA01127"

    let folder: URL
    let missingRequired: [String]
    let missingOptional: [String]
    /// Bytes of the files that are there.
    let totalBytes: Int64

    var status: DataStatus {
        missingRequired.isEmpty ? .ready : .incomplete(missingFiles: missingRequired)
    }

    /// Looks at a folder: which of the game's files are in it and how large they are.
    static func check(_ folder: URL) -> GameData {
        let manager = FileManager.default
        var missingRequired: [String] = []
        var missingOptional: [String] = []
        var total: Int64 = 0
        for name in requiredFiles + optionalFiles {
            let path = folder.appendingPathComponent(name).path
            if let attributes = try? manager.attributesOfItem(atPath: path),
               let size = attributes[.size] as? Int64 {
                total += size
            } else if requiredFiles.contains(name) {
                missingRequired.append(name)
            } else {
                missingOptional.append(name)
            }
        }
        return GameData(folder: folder, missingRequired: missingRequired, missingOptional: missingOptional, totalBytes: total)
    }

    /// Whether a folder has at least one of the game's files (so it is the game's folder, even
    /// if the copy is not complete).
    static func looksLikeGame(_ folder: URL) -> Bool {
        let manager = FileManager.default
        return requiredFiles.contains { manager.fileExists(atPath: folder.appendingPathComponent($0).path) }
    }

    /// Where the game is: the gamePath setting, else Documents, Documents/CUSA01127, or any folder
    /// one level below Documents. A complete copy is preferred over an incomplete one.
    static func find(settingPath: String) -> GameData? {
        let manager = FileManager.default
        var places: [URL] = []
        if !settingPath.isEmpty {
            var url = URL(fileURLWithPath: settingPath)
            if requiredFiles.contains(url.lastPathComponent) {
                url.deleteLastPathComponent()
            }
            places.append(url)
        }
        let documents = PTSettings.documents
        places.append(documents.appendingPathComponent(folderName, isDirectory: true))
        places.append(documents)
        let inside = (try? manager.contentsOfDirectory(at: documents, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        for url in inside.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                places.append(url)
            }
        }
        let candidates = places.filter(looksLikeGame).map(check)
        return candidates.first(where: { $0.missingRequired.isEmpty }) ?? candidates.first
    }

    static func format(bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
