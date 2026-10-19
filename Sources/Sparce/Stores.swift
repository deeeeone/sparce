import Foundation

/// Epic (via Legendary) and GOG (via gogdl), the same open-source tools Heroic uses.
enum Stores {
    // MARK: Tools

    static var legendary: URL { Paths.tools.appendingPathComponent("legendary") }
    static var gogdl: URL { Paths.tools.appendingPathComponent("gogdl") }

    static func ensureTool(_ store: StoreKind, library: Library) async throws -> URL {
        let target = store == .epic ? legendary : gogdl
        if FileManager.default.isExecutableFile(atPath: target.path) { return target }
        let (repo, asset) = store == .epic
            ? ("legendary-gl/legendary", "legendary_macOS_arm64")
            : ("Heroic-Games-Launcher/heroic-gogdl", "gogdl_macos_arm64")
        let found = try await Components.latestAsset(repo: repo, prefix: asset, suffix: "")
        let file = try await Components.download(found.url, name: asset, library: library)
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.moveItem(at: file, to: target)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target.path)
        await Components.unquarantine(target)
        return target
    }

    static func legendaryEnv() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["LEGENDARY_CONFIG_PATH"] = Paths.epicConfig.path
        return env
    }

    /// Runs a store tool and collects stdout+stderr.
    static func capture(_ tool: URL, _ args: [String], env: [String: String]? = nil,
                        onLine: (@Sendable (String) -> Void)? = nil) async throws -> String {
        let (code, out) = try await Shell.output(tool, args, environment: env, onOutput: onLine)
        if code != 0 {
            let tail = out.split(separator: "\n").suffix(3).joined(separator: "\n")
            throw ShellError(message: "\(tool.lastPathComponent) failed (\(code)): \(tail)")
        }
        return out
    }

    /// Pulls the first JSON value (object or array) out of mixed log output.
    static func extractJSON(_ text: String) -> Data? {
        guard let start = text.firstIndex(where: { $0 == "{" || $0 == "[" }) else { return nil }
        let close: Character = text[start] == "{" ? "}" : "]"
        guard let end = text.lastIndex(of: close), end >= start else { return nil }
        return String(text[start...end]).data(using: .utf8)
    }

    static func parseProgress(_ line: String) -> Double? {
        guard let r = line.range(of: #"Progress: ([0-9]+(\.[0-9]+)?)"#, options: .regularExpression) else { return nil }
        let number = line[r].replacingOccurrences(of: "Progress: ", with: "")
        return Double(number).map { min(max($0 / 100, 0), 1) }
    }

    // MARK: Epic

    static let epicLoginURL = URL(string: "https://legendary.gl/epiclogin")!

    static var epicSignedIn: Bool {
        FileManager.default.fileExists(atPath: Paths.epicConfig.appendingPathComponent("user.json").path)
    }

    static func epicLogin(code: String, library: Library) async throws {
        let tool = try await ensureTool(.epic, library: library)
        _ = try await capture(tool, ["auth", "--code", code], env: legendaryEnv()) { library.append($0) }
    }

    static func epicLogout(library: Library) async throws {
        let tool = try await ensureTool(.epic, library: library)
        _ = try await capture(tool, ["auth", "--delete"], env: legendaryEnv())
    }

    private struct EpicGame: Decodable {
        struct Meta: Decodable {
            struct KeyImage: Decodable { let type: String; let url: String }
            let keyImages: [KeyImage]?
        }
        let app_name: String
        let app_title: String
        let metadata: Meta?
    }

    private struct EpicInstalled: Decodable {
        let app_name: String
        let install_path: String
        let platform: String?
    }

    struct StoreEntry {
        var storeID: String
        var title: String
        var art: String?
        var windows: Bool
        var mac: Bool
    }

    static func epicLibrary(library: Library) async throws -> (games: [StoreEntry], installed: [String: String]) {
        let tool = try await ensureTool(.epic, library: library)
        let env = legendaryEnv()
        func list(_ platform: String) async throws -> [EpicGame] {
            let out = try await capture(tool, ["list", "--json", "--platform", platform], env: env)
            guard let data = extractJSON(out) else { return [] }
            return (try? JSONDecoder().decode([EpicGame].self, from: data)) ?? []
        }
        let windows = try await list("Windows")
        let macGames = try await list("Mac")
        let macIDs = Set(macGames.map(\.app_name))

        func art(_ g: EpicGame) -> String? {
            let images = g.metadata?.keyImages ?? []
            for type in ["DieselGameBox", "DieselGameBoxWide", "OfferImageWide", "DieselStoreFrontWide", "Thumbnail", "DieselGameBoxTall"] {
                if let hit = images.first(where: { $0.type == type }) { return hit.url }
            }
            return images.first?.url
        }

        var entries: [String: StoreEntry] = [:]
        for g in windows {
            entries[g.app_name] = StoreEntry(storeID: g.app_name, title: g.app_title, art: art(g),
                                             windows: true, mac: macIDs.contains(g.app_name))
        }
        // Mac-only titles.
        do {
            for g in macGames where entries[g.app_name] == nil {
                entries[g.app_name] = StoreEntry(storeID: g.app_name, title: g.app_title, art: art(g), windows: false, mac: true)
            }
        }

        let installedOut = try await capture(tool, ["list-installed", "--json"], env: env)
        var installed: [String: String] = [:]
        if let data = extractJSON(installedOut),
           let list = try? JSONDecoder().decode([EpicInstalled].self, from: data) {
            for item in list { installed[item.app_name] = item.install_path }
        }
        return (Array(entries.values), installed)
    }

    static func epicInstall(_ game: Game, mac: Bool, library: Library) async throws -> String {
        guard let app = game.storeID else { throw ShellError(message: "Missing Epic app id.") }
        let tool = try await ensureTool(.epic, library: library)
        let base = Paths.games.appendingPathComponent("Epic")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let id = game.id
        _ = try await capture(tool, ["-y", "install", app, "--base-path", base.path,
                                     "--platform", mac ? "Mac" : "Windows", "--skip-sdl"],
                              env: legendaryEnv()) { line in
            library.append(line)
            if let p = parseProgress(line) { Task { @MainActor in library.progress[id] = p } }
        }
        let (_, installed) = try await epicLibrary(library: library)
        guard let path = installed[app] else { throw ShellError(message: "Install finished but Legendary doesn't list it.") }
        return path
    }

    static func epicUninstall(_ game: Game, library: Library) async throws {
        guard let app = game.storeID else { return }
        let tool = try await ensureTool(.epic, library: library)
        _ = try await capture(tool, ["-y", "uninstall", app], env: legendaryEnv()) { library.append($0) }
    }

    struct LaunchPlan {
        var executable: URL
        var arguments: [String]
        var workingDirectory: URL?
        var environment: [String: String]
    }

    private struct EpicLaunch: Decodable {
        let game_parameters: [String]?
        let game_executable: String
        let game_directory: String
        let egl_parameters: [String]?
        let working_directory: String?
        let user_parameters: [String]?
        let environment: [String: String]?
    }

    /// Asks Legendary for the launch command (incl. Epic auth tokens) so Sparce can run it with its own Wine setup.
    static func epicLaunchPlan(_ game: Game, library: Library) async throws -> LaunchPlan {
        guard let app = game.storeID else { throw ShellError(message: "Missing Epic app id.") }
        let tool = try await ensureTool(.epic, library: library)
        let out = try await capture(tool, ["launch", app, "--json", "--skip-version-check"], env: legendaryEnv())
        guard let data = extractJSON(out) else { throw ShellError(message: "Legendary gave no launch info.") }
        let p = try JSONDecoder().decode(EpicLaunch.self, from: data)
        let exe = URL(fileURLWithPath: p.game_directory).appendingPathComponent(p.game_executable)
        return LaunchPlan(
            executable: exe,
            arguments: (p.game_parameters ?? []) + (p.egl_parameters ?? []) + (p.user_parameters ?? []),
            workingDirectory: p.working_directory.flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) },
            environment: p.environment ?? [:])
    }

    // MARK: GOG

    static let gogClientID = "46899977096215655"
    static let gogLoginURL = URL(string:
        "https://auth.gog.com/auth?client_id=\(gogClientID)&redirect_uri=https%3A%2F%2Fembed.gog.com%2Fon_login_success%3Forigin%3Dclient&response_type=code&layout=galaxy")!

    static var gogSignedIn: Bool { FileManager.default.fileExists(atPath: Paths.gogAuth.path) }

    static func gog(_ args: [String], library: Library, onLine: (@Sendable (String) -> Void)? = nil) async throws -> String {
        let tool = try await ensureTool(.gog, library: library)
        return try await capture(tool, ["--auth-config-path", Paths.gogAuth.path] + args, onLine: onLine)
    }

    static func gogLogin(code: String, library: Library) async throws {
        _ = try await gog(["auth", "--code", code], library: library)
    }

    static func gogLogout() {
        try? FileManager.default.removeItem(at: Paths.gogAuth)
    }

    /// gogdl refreshes and prints the credentials when called without a code.
    static func gogToken(library: Library) async throws -> String {
        let out = try await gog(["auth"], library: library)
        guard let data = extractJSON(out),
              let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = obj["access_token"] as? String else {
            throw ShellError(message: "GOG sign-in expired. Sign in again.")
        }
        return token
    }

    private struct GOGPage: Decodable {
        struct Product: Decodable {
            struct WorksOn: Decodable { let Windows: Bool?; let Mac: Bool? }
            let id: Int
            let title: String
            let image: String?
            let worksOn: WorksOn?
        }
        let totalPages: Int
        let products: [Product]
    }

    static func gogLibrary(library: Library) async throws -> [StoreEntry] {
        let token = try await gogToken(library: library)
        var entries: [StoreEntry] = []
        var page = 1
        var total = 1
        repeat {
            var request = URLRequest(url: URL(string: "https://embed.gog.com/account/getFilteredProducts?mediaType=1&page=\(page)")!)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let (data, _) = try await URLSession.shared.data(for: request)
            let result = try JSONDecoder().decode(GOGPage.self, from: data)
            total = result.totalPages
            for p in result.products {
                let art = p.image.map { ($0.hasPrefix("//") ? "https:" + $0 : $0) + "_392.jpg" }
                entries.append(StoreEntry(storeID: String(p.id), title: p.title, art: art,
                                          windows: p.worksOn?.Windows ?? true, mac: p.worksOn?.Mac ?? false))
            }
            page += 1
        } while page <= total
        return entries
    }

    static func gogInstall(_ game: Game, mac: Bool, library: Library) async throws -> URL {
        guard let id = game.storeID else { throw ShellError(message: "Missing GOG id.") }
        let dir = Paths.games.appendingPathComponent("GOG/\(game.name.slug)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let gameID = game.id
        _ = try await gog(["download", id, "--platform", mac ? "osx" : "windows", "--path", dir.path,
                           "--skip-dlcs", "--lang", "en-US"], library: library) { line in
            library.append(line)
            if let p = parseProgress(line) { Task { @MainActor in library.progress[gameID] = p } }
        }
        return dir
    }

    private struct GOGInfo: Decodable {
        struct PlayTask: Decodable {
            let isPrimary: Bool?
            let category: String?
            let type: String?
            let path: String?
            let workingDir: String?
            let arguments: String?
        }
        let playTasks: [PlayTask]?
    }

    /// Finds what to run inside a GOG install.
    static func gogExecutable(in dir: URL, storeID: String, mac: Bool) -> (exe: URL, workDir: URL?, args: String)? {
        if mac {
            let apps = FileSearch.all(under: dir, maxDepth: 3) { $0.pathExtension == "app" }
            return apps.first.map { ($0, nil, "") }
        }
        guard let info = FileSearch.first(named: "goggame-\(storeID).info", under: dir, maxDepth: 4),
              let data = try? Data(contentsOf: info),
              let parsed = try? JSONDecoder().decode(GOGInfo.self, from: data) else {
            let exes = FileSearch.all(under: dir, maxDepth: 2) { $0.pathExtension.lowercased() == "exe" }
            return exes.first.map { ($0, nil, "") }
        }
        let root = info.deletingLastPathComponent()
        let tasks = (parsed.playTasks ?? []).filter { $0.type == nil || $0.type == "FileTask" }
        guard let task = tasks.first(where: { $0.isPrimary == true }) ?? tasks.first, let path = task.path else { return nil }
        let exe = root.appendingPathComponent(path.replacingOccurrences(of: "\\", with: "/"))
        let work = task.workingDir.map { root.appendingPathComponent($0.replacingOccurrences(of: "\\", with: "/")) }
        return (exe, work, task.arguments ?? "")
    }

    // MARK: Sync into the library

    @MainActor
    static func sync(library: Library) async throws {
        library.syncing = true
        defer { library.syncing = false }
        if Stores.epicSignedIn {
            let (games, installed) = try await epicLibrary(library: library)
            merge(games, store: .epic, installed: installed, into: library)
        }
        if Stores.gogSignedIn {
            let games = try await gogLibrary(library: library)
            merge(games, store: .gog, installed: [:], into: library)
        }
        library.epicSignedIn = epicSignedIn
        library.gogSignedIn = gogSignedIn
        library.append("Library synced: \(library.games.filter { $0.store != nil }.count) store games.")
    }

    @MainActor
    private static func merge(_ entries: [StoreEntry], store: StoreKind, installed: [String: String], into library: Library) {
        for entry in entries {
            if let i = library.games.firstIndex(where: { $0.store == store && $0.storeID == entry.storeID }) {
                library.games[i].name = entry.title
                library.games[i].artURL = entry.art
                library.games[i].hasMacVersion = entry.mac
                if store == .epic {
                    library.games[i].installed = installed[entry.storeID] != nil
                    library.games[i].installPath = installed[entry.storeID]
                }
            } else {
                var game = Game(name: entry.title, kind: .windows, executable: "",
                                bottleID: library.defaultBottle?.id)
                game.store = store
                game.storeID = entry.storeID
                game.artURL = entry.art
                game.hasMacVersion = entry.mac
                game.installed = installed[entry.storeID] != nil
                game.installPath = installed[entry.storeID]
                if let tip = Compatibility.tip(for: entry.title) { game.settings.backend = tip.backend ?? game.settings.backend }
                library.games.append(game)
            }
        }
    }

    // MARK: Install / uninstall

    @MainActor
    static func install(_ game: Game, library: Library) async throws {
        let mac = (game.hasMacVersion ?? false) && library.preferMacVersions
        if !mac, library.defaultBottle == nil {
            throw ShellError(message: "Create a bottle in the Bottles tab first (needed for Windows games).")
        }
        library.progress[game.id] = 0
        defer { library.progress[game.id] = nil }

        switch game.store {
        case .epic:
            let path = try await epicInstall(game, mac: mac, library: library)
            library.update(game.id) {
                $0.installed = true
                $0.installPath = path
                $0.kind = mac ? .macApp : .windows
                if $0.bottleID == nil { $0.bottleID = library.defaultBottle?.id }
            }
        case .gog:
            let dir = try await gogInstall(game, mac: mac, library: library)
            guard let id = game.storeID, let found = gogExecutable(in: dir, storeID: id, mac: mac) else {
                throw ShellError(message: "Installed, but couldn't find the game's executable in \(dir.path).")
            }
            library.update(game.id) {
                $0.installed = true
                $0.installPath = dir.path
                $0.executable = found.exe.path
                $0.workingDirectory = found.workDir?.path
                if $0.settings.arguments.isEmpty { $0.settings.arguments = found.args }
                $0.kind = mac ? .macApp : .windows
                if $0.bottleID == nil { $0.bottleID = library.defaultBottle?.id }
            }
        case nil:
            break
        }
    }

    @MainActor
    static func uninstall(_ game: Game, library: Library) async throws {
        switch game.store {
        case .epic:
            try await epicUninstall(game, library: library)
        case .gog:
            if let path = game.installPath { try? FileManager.default.removeItem(atPath: path) }
        case nil:
            return
        }
        library.update(game.id) {
            $0.installed = false
            $0.installPath = nil
            $0.executable = ""
        }
    }
}

/// Thread-safe line buffer for process output.
final class LineCollector: @unchecked Sendable {
    private var lines: [String] = []
    private let lock = NSLock()
    func add(_ line: String) { lock.lock(); lines.append(line); lock.unlock() }
    var text: String { lock.lock(); defer { lock.unlock() }; return lines.joined(separator: "\n") }
}
