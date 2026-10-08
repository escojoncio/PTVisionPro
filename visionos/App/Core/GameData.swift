// SPDX-License-Identifier: MIT
//
// The game's data: the CUSA01127 folder of the PlayStation 4 release, in VPS4/Juegos (see
// VPS4Folder), or else in the app's own Documents. What the core needs of it is chunk1.psarc
// (the game's files) and texture.qar (its textures); param.sfo and pathid_list_ps4.bin are good
// to have. The exact sizes of the two big files tell the release the port is made for (the US
// CUSA01127 v01.00) from any other.

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
    /// The sizes of the US v01.00 files (pt-ipad's verified catalogue).
    static let knownSizes: [String: Int64] = ["chunk1.psarc": 421_978_112, "texture.qar": 892_291_044]

    let folder: URL
    let missingRequired: [String]
    let missingOptional: [String]
    /// Bytes of the files that are there.
    let totalBytes: Int64
    /// The required files that are there but not of the US v01.00 size (another release, or a
    /// copy that did not finish).
    let unexpectedSize: [String]
    /// The folder is inside VPS4.
    var inVPS4: Bool {
        guard let root = VPS4Folder.shared.url else { return false }
        return folder.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path)
    }

    var status: DataStatus {
        missingRequired.isEmpty ? .ready : .incomplete(missingFiles: missingRequired)
    }

    /// Looks at a folder: which of the game's files are in it and how large they are.
    static func check(_ folder: URL) -> GameData {
        let manager = FileManager.default
        var missingRequired: [String] = []
        var missingOptional: [String] = []
        var unexpected: [String] = []
        var total: Int64 = 0
        for name in requiredFiles + optionalFiles {
            let path = folder.appendingPathComponent(name).path
            if let attributes = try? manager.attributesOfItem(atPath: path),
               let size = (attributes[.size] as? NSNumber)?.int64Value {
                total += size
                if let known = knownSizes[name], known != size {
                    unexpected.append(name)
                }
            } else if requiredFiles.contains(name) {
                missingRequired.append(name)
            } else {
                missingOptional.append(name)
            }
        }
        return GameData(folder: folder, missingRequired: missingRequired, missingOptional: missingOptional, totalBytes: total,
                        unexpectedSize: unexpected)
    }

    /// Whether a folder has at least one of the game's files (so it is the game's folder, even
    /// if the copy is not complete).
    static func looksLikeGame(_ folder: URL) -> Bool {
        let manager = FileManager.default
        return requiredFiles.contains { manager.fileExists(atPath: folder.appendingPathComponent($0).path) }
    }

    /// Where the game is: VPS4/Juegos/CUSA01127, any other folder in VPS4/Juegos, VPS4/CUSA01127;
    /// then the gamePath setting, Documents/CUSA01127, Documents, or any folder one level below
    /// Documents. A complete copy of the right release is preferred, then any complete copy.
    static func find(settingPath: String) -> GameData? {
        let manager = FileManager.default
        var places: [URL] = []
        if let root = VPS4Folder.shared.url, let games = VPS4Folder.shared.games {
            places.append(games.appendingPathComponent(folderName, isDirectory: true))
            let inside = (try? manager.contentsOfDirectory(at: games, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
            for url in inside.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    places.append(url)
                }
            }
            places.append(root.appendingPathComponent(folderName, isDirectory: true))
        }
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
        return candidates.first(where: { $0.missingRequired.isEmpty && $0.unexpectedSize.isEmpty })
            ?? candidates.first(where: { $0.missingRequired.isEmpty })
            ?? candidates.first
    }

    static func format(bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
