import Foundation

/// Works out how well a game should run on this Mac.
///
/// Sources, in order of trust:
/// 1. Your own rating (set after you've played).
/// 2. The store says there's a Mac version.
/// 3. AreWeAntiCheatYet data: games whose anti-cheat blocks Wine/Proton.
/// 4. A small built-in list of tips.
struct CompatInfo {
    var rating: CompatRating
    var source: String
    var notes: [String]
    var recommendedBackend: GraphicsBackend?
}

struct CompatTip {
    var rating: CompatRating
    var backend: GraphicsBackend?
    var note: String
}

@MainActor
final class Compatibility: ObservableObject {
    static let shared = Compatibility()

    struct AntiCheatEntry: Codable {
        let name: String
        let status: String
        let anticheats: [String]
    }

    @Published private(set) var antiCheat: [String: AntiCheatEntry] = [:]
    private var loaded = false

    private static let dataURL = URL(string: "https://raw.githubusercontent.com/AreWeAntiCheatYet/AreWeAntiCheatYet/HEAD/games.json")!
    private static var cacheFile: URL { Paths.cache.appendingPathComponent("anticheat.json") }

    /// Loads the cached anti-cheat list, then refreshes it if older than a week.
    func load() async {
        guard !loaded else { return }
        loaded = true
        if let data = try? Data(contentsOf: Self.cacheFile) { ingest(data) }
        let age = (try? Self.cacheFile.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            .map { Date().timeIntervalSince($0) } ?? .infinity
        guard age > 7 * 24 * 3600 else { return }
        if let result = try? await URLSession.shared.data(from: Self.dataURL) {
            let data = result.0
            ingest(data)
            try? data.write(to: Self.cacheFile, options: .atomic)
        }
    }

    private func ingest(_ data: Data) {
        guard let list = try? JSONDecoder().decode([AntiCheatEntry].self, from: data) else { return }
        var map: [String: AntiCheatEntry] = [:]
        for e in list { map[Self.normalize(e.name)] = e }
        antiCheat = map
    }

    nonisolated static func normalize(_ title: String) -> String {
        let lowered = title.lowercased()
            .replacingOccurrences(of: "™", with: "")
            .replacingOccurrences(of: "®", with: "")
        let kept = lowered.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
        return String(String.UnicodeScalarView(kept))
    }

    func info(for game: Game) -> CompatInfo {
        var notes: [String] = []
        let key = Self.normalize(game.name)
        let ac = antiCheat[key]
        let tip = Self.tip(for: game.name)

        if let ac {
            let names = ac.anticheats.joined(separator: ", ")
            if !names.isEmpty { notes.append("Uses \(names).") }
        }
        if let tip { notes.append(tip.note) }

        if let user = game.userRating {
            return CompatInfo(rating: user, source: "Your rating", notes: notes, recommendedBackend: tip?.backend)
        }
        if game.hasMacVersion == true || game.kind == .macApp || game.kind == .ps5Native {
            return CompatInfo(rating: .native, source: game.kind == .ps5Native ? "AnyPS5 port" : "Store",
                              notes: notes, recommendedBackend: nil)
        }
        if let ac, ac.status == "Denied" || ac.status == "Broken" {
            notes.insert("Its anti-cheat doesn't run under Wine, so online play (often the whole game) won't work.", at: 0)
            return CompatInfo(rating: .blocked, source: "AreWeAntiCheatYet", notes: notes, recommendedBackend: nil)
        }
        if let tip {
            return CompatInfo(rating: tip.rating, source: "Sparce tips", notes: notes, recommendedBackend: tip.backend)
        }
        if let ac, !ac.anticheats.isEmpty, ac.anticheats != ["VAC"] {
            notes.insert("Has anti-cheat that works on Linux/Proton but isn't confirmed on Mac. Offline modes are the safest bet.", at: 0)
            return CompatInfo(rating: .issues, source: "AreWeAntiCheatYet", notes: notes, recommendedBackend: nil)
        }
        return CompatInfo(rating: .unknown, source: "No data yet",
                          notes: notes + ["Try D3DMetal first, then DXMT, then DXVK, and rate it once you know."],
                          recommendedBackend: nil)
    }

    /// Hand-checked tips for well-known titles.
    nonisolated static func tip(for title: String) -> CompatTip? {
        tips[normalize(title)]
    }

    nonisolated private static let tips: [String: CompatTip] = {
        let list: [(String, CompatTip)] = [
            ("Elden Ring", CompatTip(rating: .works, backend: .d3dmetal,
                note: "Runs with D3DMetal. Start it in offline mode: Easy Anti-Cheat blocks online play.")),
            ("Hogwarts Legacy", CompatTip(rating: .works, backend: .d3dmetal,
                note: "Runs with D3DMetal. Turn off raytracing on base M-series chips.")),
            ("The Witcher 3: Wild Hunt", CompatTip(rating: .works, backend: .d3dmetal,
                note: "Use the DX11 version if DX12 stutters.")),
            ("Hades", CompatTip(rating: .works, backend: .d3dmetal, note: "Light game, runs well even on a MacBook Air.")),
            ("Hollow Knight", CompatTip(rating: .works, backend: .d3dmetal, note: "Has a native Mac version; prefer it.")),
            ("Fortnite", CompatTip(rating: .blocked, backend: nil, note: "Kernel anti-cheat. Use GeForce NOW or Xbox Cloud Gaming instead.")),
            ("Rocket League", CompatTip(rating: .blocked, backend: nil, note: "Easy Anti-Cheat blocks it under Wine.")),
            ("Fall Guys", CompatTip(rating: .blocked, backend: nil, note: "Easy Anti-Cheat blocks it under Wine.")),
            ("Genshin Impact", CompatTip(rating: .blocked, backend: nil, note: "Anti-cheat blocks it under Wine.")),
        ]
        var map: [String: CompatTip] = [:]
        for (name, tip) in list { map[normalize(name)] = tip }
        return map
    }()

    nonisolated static func lookupURL(for title: String) -> URL? {
        var c = URLComponents(string: "https://www.applegamingwiki.com/w/index.php")
        c?.queryItems = [URLQueryItem(name: "search", value: title)]
        return c?.url
    }
}
