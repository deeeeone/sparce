import Foundation

enum Paths {
    static let support: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Sparce", isDirectory: true)
    }()

    static var engines: URL { support.appendingPathComponent("Engines", isDirectory: true) }
    static var bottles: URL { support.appendingPathComponent("Bottles", isDirectory: true) }
    static var components: URL { support.appendingPathComponent("Components", isDirectory: true) }
    static var dxvk: URL { components.appendingPathComponent("dxvk", isDirectory: true) }
    static var dxmt: URL { components.appendingPathComponent("dxmt", isDirectory: true) }
    static var ps5: URL { support.appendingPathComponent("PS5", isDirectory: true) }
    static var downloads: URL { support.appendingPathComponent("Downloads", isDirectory: true) }
    static var libraryFile: URL { support.appendingPathComponent("library.json") }
    static var tools: URL { support.appendingPathComponent("Tools", isDirectory: true) }
    static var epicConfig: URL { support.appendingPathComponent("Epic", isDirectory: true) }
    static var gogConfig: URL { support.appendingPathComponent("GOG", isDirectory: true) }
    static var gogAuth: URL { gogConfig.appendingPathComponent("auth.json") }
    static var cache: URL { support.appendingPathComponent("Cache", isDirectory: true) }

    /// Where store games get installed.
    static let games: URL = {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Games/Sparce", isDirectory: true)
    }()

    static let logs: URL = {
        let base = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Logs/Sparce", isDirectory: true)
    }()

    static func ensureAll() {
        for dir in [support, engines, bottles, components, dxvk, dxmt, ps5, downloads, logs,
                    tools, epicConfig, gogConfig, cache, games] {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }
}

enum FileSearch {
    /// Breadth-first search for a file or folder with an exact name.
    static func first(named name: String, under root: URL, maxDepth: Int = 6) -> URL? {
        all(under: root, maxDepth: maxDepth) { $0.lastPathComponent == name }.first
    }

    static func all(under root: URL, maxDepth: Int = 6, where match: (URL) -> Bool) -> [URL] {
        let fm = FileManager.default
        var results: [URL] = []
        var queue: [(URL, Int)] = [(root, 0)]
        while !queue.isEmpty {
            let (dir, depth) = queue.removeFirst()
            guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { continue }
            for item in items {
                if match(item) { results.append(item) }
                let values = try? item.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                if values?.isDirectory == true, values?.isSymbolicLink != true, depth < maxDepth,
                   item.pathExtension != "framework" {
                    queue.append((item, depth + 1))
                }
            }
        }
        return results
    }

    /// Finds a Wine launcher binary inside an extracted engine. Prefers `wine64` (older builds) then `wine`.
    static func wineBinary(under root: URL) -> URL? {
        let candidates = all(under: root, maxDepth: 7) { url in
            (url.lastPathComponent == "wine64" || url.lastPathComponent == "wine")
                && url.deletingLastPathComponent().lastPathComponent == "bin"
        }
        return candidates.first { $0.lastPathComponent == "wine64" } ?? candidates.first
    }
}

extension String {
    var slug: String {
        let allowed = CharacterSet.alphanumerics
        let parts = unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        let s = String(parts).lowercased()
        return s.split(separator: "-").joined(separator: "-")
    }
}
