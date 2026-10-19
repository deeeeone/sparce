import Foundation

/// A downloadable Wine engine.
struct EngineSource: Identifiable {
    let id: String
    let name: String
    let detail: String
    let repo: String
    let assetPrefix: String
    let assetSuffix: String

    static let all: [EngineSource] = [
        EngineSource(
            id: "gptk",
            name: "Game Porting Toolkit 3",
            detail: "Apple's Wine with D3DMetal (DX11/DX12). Recommended. Built by Gcenx.",
            repo: "Gcenx/game-porting-toolkit",
            assetPrefix: "game-porting-toolkit-",
            assetSuffix: ".tar.xz"),
        EngineSource(
            id: "wine-staging",
            name: "Wine Staging",
            detail: "Latest upstream Wine for macOS. Use with DXVK or WineD3D.",
            repo: "Gcenx/macOS_Wine_builds",
            assetPrefix: "wine-staging-",
            assetSuffix: "-osx64.tar.xz"),
    ]
}

private struct GitHubRelease: Decodable {
    struct Asset: Decodable {
        let name: String
        let browser_download_url: URL
    }
    let tag_name: String
    let assets: [Asset]
}

enum Components {
    // MARK: Download helpers

    static func latestAsset(repo: String, prefix: String, suffix: String,
                            excluding: String? = nil) async throws -> (tag: String, url: URL, name: String) {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Sparce", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw ShellError(message: "GitHub returned \(http.statusCode) for \(repo)")
        }
        let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
        guard let asset = release.assets.first(where: { asset in
            guard asset.name.hasPrefix(prefix), asset.name.hasSuffix(suffix) else { return false }
            if let excluding, asset.name.contains(excluding) { return false }
            return true
        }) else {
            throw ShellError(message: "No download matching \(prefix)*\(suffix) in \(repo) \(release.tag_name)")
        }
        return (release.tag_name, asset.browser_download_url, asset.name)
    }

    static func download(_ url: URL, name: String, library: Library) async throws -> URL {
        library.append("Downloading \(name)…")
        let (temp, response) = try await URLSession.shared.download(from: url)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw ShellError(message: "Download failed (\(http.statusCode))")
        }
        let dest = Paths.downloads.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: temp, to: dest)
        return dest
    }

    static func extract(_ archive: URL, into dir: URL, library: Library) async throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        library.append("Extracting \(archive.lastPathComponent)…")
        try await Shell.check(Shell.tar, ["-xf", archive.path, "-C", dir.path]) { library.append($0) }
        try? FileManager.default.removeItem(at: archive)
    }

    static func unquarantine(_ url: URL) async {
        _ = try? await Shell.run(Shell.xattr, ["-dr", "com.apple.quarantine", url.path])
    }

    // MARK: Engines

    static func install(_ source: EngineSource, library: Library) async throws {
        let asset = try await latestAsset(repo: source.repo, prefix: source.assetPrefix, suffix: source.assetSuffix)
        let archive = try await download(asset.url, name: asset.name, library: library)
        let dir = Paths.engines.appendingPathComponent("\(source.name) \(asset.tag)".replacingOccurrences(of: "/", with: "-"))
        try? FileManager.default.removeItem(at: dir)
        try await extract(archive, into: dir, library: library)
        await unquarantine(dir)
        guard FileSearch.wineBinary(under: dir) != nil else {
            throw ShellError(message: "Couldn't find a wine binary in the download.")
        }
        await MainActor.run { library.refreshEngines() }
    }

    /// Registers a Wine build that lives somewhere else (e.g. a CrossOver-based build for DXMT).
    @MainActor
    static func importEngine(folder: URL, library: Library) throws {
        guard let wine = FileSearch.wineBinary(under: folder) else {
            throw ShellError(message: "No bin/wine or bin/wine64 found in that folder.")
        }
        let engine = Engine(id: "custom-\(folder.path.slug)", name: folder.lastPathComponent,
                            root: folder.path, wineBinary: wine.path)
        library.customEngines.removeAll { $0.id == engine.id }
        library.customEngines.append(engine)
    }

    /// Merges Apple's D3DMetal redistributable (the `redist/lib` folder from the
    /// Game Porting Toolkit disk image) into an engine. Apple's licence doesn't
    /// allow Sparce to download it for you.
    static func importD3DMetal(redistLib: URL, into engine: Engine, library: Library) async throws {
        var src = redistLib
        if src.lastPathComponent != "lib", FileManager.default.fileExists(atPath: src.appendingPathComponent("lib").path) {
            src = src.appendingPathComponent("lib")
        }
        guard FileSearch.first(named: "D3DMetal.framework", under: src, maxDepth: 4) != nil else {
            throw ShellError(message: "That folder doesn't contain D3DMetal.framework. Pick redist/lib from the Game Porting Toolkit image.")
        }
        try FileManager.default.createDirectory(at: engine.libDir, withIntermediateDirectories: true)
        try await Shell.check(Shell.ditto, [src.path, engine.libDir.path]) { library.append($0) }
        await unquarantine(engine.libDir)
    }

    // MARK: DXVK (macOS fork by Gcenx, works with MoltenVK)

    static var dxvkInstalled: Bool {
        FileManager.default.fileExists(atPath: Paths.dxvk.appendingPathComponent("x64/d3d11.dll").path)
    }

    static func installDXVK(library: Library) async throws {
        // The non-"builtin" archive holds plain x64/x32 DLLs we copy into the bottle.
        let asset = try await latestAsset(repo: "Gcenx/DXVK-macOS", prefix: "dxvk-macOS", suffix: ".tar.gz",
                                          excluding: "builtin")
        let archive = try await download(asset.url, name: asset.name, library: library)
        let tmp = Paths.downloads.appendingPathComponent("dxvk-extract")
        try? FileManager.default.removeItem(at: tmp)
        try await extract(archive, into: tmp, library: library)
        guard let d3d11 = FileSearch.all(under: tmp, maxDepth: 4, where: {
            $0.lastPathComponent == "d3d11.dll" && $0.deletingLastPathComponent().lastPathComponent == "x64"
        }).first else {
            throw ShellError(message: "Unexpected DXVK archive layout.")
        }
        let base = d3d11.deletingLastPathComponent().deletingLastPathComponent()
        try? FileManager.default.removeItem(at: Paths.dxvk)
        try FileManager.default.moveItem(at: base, to: Paths.dxvk)
        try? FileManager.default.removeItem(at: tmp)
    }

    // MARK: DXMT (no official releases yet: import a build folder)

    static var dxmtInstalled: Bool {
        FileManager.default.fileExists(atPath: Paths.dxmt.appendingPathComponent("unix/winemetal.so").path)
    }

    static func importDXMT(folder: URL) throws {
        let fm = FileManager.default
        guard let so = FileSearch.first(named: "winemetal.so", under: folder, maxDepth: 5) else {
            throw ShellError(message: "No winemetal.so found. Pick the extracted DXMT build folder.")
        }
        // Prefer 64-bit Windows DLLs.
        let dlls = FileSearch.all(under: folder, maxDepth: 5) { $0.lastPathComponent == "d3d11.dll" }
        guard let d3d11 = dlls.first(where: { $0.path.contains("x86_64") || $0.path.contains("64") }) ?? dlls.first else {
            throw ShellError(message: "No d3d11.dll found in the DXMT folder.")
        }
        let winSrc = d3d11.deletingLastPathComponent()
        let win = Paths.dxmt.appendingPathComponent("windows")
        let unix = Paths.dxmt.appendingPathComponent("unix")
        try? fm.removeItem(at: Paths.dxmt)
        try fm.createDirectory(at: unix, withIntermediateDirectories: true)
        try fm.copyItem(at: winSrc, to: win)
        try fm.copyItem(at: so, to: unix.appendingPathComponent("winemetal.so"))
        if !fm.fileExists(atPath: win.appendingPathComponent("winemetal.dll").path),
           let metal = FileSearch.first(named: "winemetal.dll", under: folder, maxDepth: 5) {
            try fm.copyItem(at: metal, to: win.appendingPathComponent("winemetal.dll"))
        }
    }

    // MARK: System checks

    static var rosettaInstalled: Bool {
        FileManager.default.fileExists(atPath: "/Library/Apple/usr/libexec/oah/libRosettaRuntime")
    }

    static func installRosetta(library: Library) async throws {
        try await Shell.check(URL(fileURLWithPath: "/usr/sbin/softwareupdate"),
                              ["--install-rosetta", "--agree-to-license"]) { library.append($0) }
    }

    // MARK: Steam

    static func installSteam(bottle: Bottle, engine: Engine, library: Library) async throws {
        let url = URL(string: "https://cdn.cloudflare.steamstatic.com/client/installer/SteamSetup.exe")!
        let setup = try await download(url, name: "SteamSetup.exe", library: library)
        try await WineRunner.wine([setup.path, "/S"], bottle: bottle, engine: engine, library: library)
        try await WineRunner.waitForServer(bottle: bottle, engine: engine)
    }

    static func steamExecutable(in bottle: Bottle) -> URL {
        bottle.driveC.appendingPathComponent("Program Files (x86)/Steam/steam.exe")
    }
}

