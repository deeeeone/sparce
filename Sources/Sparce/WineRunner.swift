import Foundation

/// Builds environments and runs things inside a Wine bottle.
enum WineRunner {
    static func baseEnvironment(bottle: Bottle) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["WINEPREFIX"] = bottle.prefixURL.path
        // Stop Wine from creating Linux-style desktop menu entries.
        env["WINEDLLOVERRIDES"] = "winemenubuilder.exe=d"
        return env
    }

    /// Environment tuned for playing a game.
    static func gameEnvironment(game: Game, bottle: Bottle, engine: Engine) -> [String: String] {
        let s = game.settings
        var env = baseEnvironment(bottle: bottle)
        var overrides = ["winemenubuilder.exe=d"]

        if s.quietLogs { env["WINEDEBUG"] = "-all" }
        if s.msync {
            env["WINEMSYNC"] = "1"
            env["WINEESYNC"] = "1"
        }
        if s.advertiseAVX { env["ROSETTA_ADVERTISE_AVX"] = "1" }
        if s.metalHUD { env["MTL_HUD_ENABLED"] = "1" }

        if game.kind == .windows {
            switch s.backend {
            case .d3dmetal:
                // D3DMetal ships as Wine builtins inside the engine.
                overrides.append("dxgi,d3d9,d3d10core,d3d11,d3d12=b")
                if s.raytracing { env["D3DM_SUPPORT_DXR"] = "1" }
            case .dxmt:
                overrides.append("dxgi,d3d11,d3d10core=n,b")
            case .dxvk:
                overrides.append("dxgi,d3d9,d3d10core,d3d11=n,b")
                env["DXVK_ASYNC"] = "1"
                env["DXVK_STATE_CACHE_PATH"] = bottle.prefixURL.appendingPathComponent("dxvk-cache").path
                if s.fpsLimit > 0 { env["DXVK_FRAME_RATE"] = String(s.fpsLimit) }
                if s.metalHUD { env["DXVK_HUD"] = "fps" }
            case .wined3d:
                overrides.append("dxgi,d3d9,d3d10core,d3d11,d3d12=b")
                env["MTL_HUD_ENABLED"] = nil
            }
        }

        env["WINEDLLOVERRIDES"] = overrides.joined(separator: ";")
        for (k, v) in Shell.parseEnv(s.extraEnv) { env[k] = v }
        return env
    }

    /// Runs `wine <args>` in a bottle and waits.
    static func wine(_ args: [String], bottle: Bottle, engine: Engine, library: Library) async throws {
        let env = baseEnvironment(bottle: bottle)
        try await Shell.check(URL(fileURLWithPath: engine.wineBinary), args, environment: env) { line in
            library.append(line)
        }
    }

    static func createBottle(_ bottle: Bottle, engine: Engine, library: Library) async throws {
        try FileManager.default.createDirectory(at: bottle.prefixURL, withIntermediateDirectories: true)
        try await wine(["wineboot", "--init"], bottle: bottle, engine: engine, library: library)
        try await wine(["winecfg", "-v", "win10"], bottle: bottle, engine: engine, library: library)
        try await waitForServer(bottle: bottle, engine: engine)
    }

    static func waitForServer(bottle: Bottle, engine: Engine) async throws {
        try await Shell.run(engine.wineserver, ["-w"], environment: baseEnvironment(bottle: bottle))
    }

    static func killAll(bottle: Bottle, engine: Engine) async {
        _ = try? await Shell.run(engine.wineserver, ["-k"], environment: baseEnvironment(bottle: bottle))
    }

    static func setRetina(_ on: Bool, bottle: Bottle, engine: Engine, library: Library) async throws {
        try await wine(["reg", "add", "HKCU\\Software\\Wine\\Mac Driver", "/v", "RetinaMode",
                        "/t", "REG_SZ", "/d", on ? "y" : "n", "/f"],
                       bottle: bottle, engine: engine, library: library)
    }

    /// Copies the chosen translation layer's DLLs into the bottle before launch.
    static func prepareBackend(_ backend: GraphicsBackend, bottle: Bottle, engine: Engine) throws {
        let fm = FileManager.default
        let system32 = bottle.driveC.appendingPathComponent("windows/system32")
        let syswow64 = bottle.driveC.appendingPathComponent("windows/syswow64")

        func copyDLLs(from dir: URL, to dest: URL) throws {
            guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
            try fm.createDirectory(at: dest, withIntermediateDirectories: true)
            for file in files where file.pathExtension.lowercased() == "dll" {
                let target = dest.appendingPathComponent(file.lastPathComponent)
                try? fm.removeItem(at: target)
                try fm.copyItem(at: file, to: target)
            }
        }

        switch backend {
        case .d3dmetal:
            guard engine.hasD3DMetal else {
                throw ShellError(message: "The engine \"\(engine.name)\" has no D3DMetal. Install the Game Porting Toolkit engine or import Apple's D3DMetal in Components.")
            }
        case .dxvk:
            let x64 = Paths.dxvk.appendingPathComponent("x64")
            guard fm.fileExists(atPath: x64.path) else {
                throw ShellError(message: "DXVK isn't installed. Get it in Components.")
            }
            try copyDLLs(from: x64, to: system32)
            try copyDLLs(from: Paths.dxvk.appendingPathComponent("x32"), to: syswow64)
        case .dxmt:
            let win = Paths.dxmt.appendingPathComponent("windows")
            let unixSO = Paths.dxmt.appendingPathComponent("unix/winemetal.so")
            guard fm.fileExists(atPath: win.path), fm.fileExists(atPath: unixSO.path) else {
                throw ShellError(message: "DXMT isn't installed. Import it in Components.")
            }
            try copyDLLs(from: win, to: system32)
            // winemetal has a unix side that must live inside the engine.
            try fm.createDirectory(at: engine.unixDir, withIntermediateDirectories: true)
            let soTarget = engine.unixDir.appendingPathComponent("winemetal.so")
            try? fm.removeItem(at: soTarget)
            try fm.copyItem(at: unixSO, to: soTarget)
            let metalDLL = win.appendingPathComponent("winemetal.dll")
            if fm.fileExists(atPath: metalDLL.path) {
                try fm.createDirectory(at: engine.windowsDir, withIntermediateDirectories: true)
                let t = engine.windowsDir.appendingPathComponent("winemetal.dll")
                try? fm.removeItem(at: t)
                try fm.copyItem(at: metalDLL, to: t)
            }
        case .wined3d:
            break
        }
    }

    /// Launches a game and tracks the process.
    @MainActor
    static func launch(_ game: Game, library: Library) async throws {
        let logFile = Paths.logs.appendingPathComponent("\(game.name.slug).log")
        let args = Shell.splitArguments(game.settings.arguments)
        let exe = URL(fileURLWithPath: game.executable)
        let workDir = game.workingDirectory.map { URL(fileURLWithPath: $0) } ?? exe.deletingLastPathComponent()

        let id = game.id
        let name = game.name
        let onExit: @Sendable (Int32) -> Void = { status in
            Task { @MainActor in
                library.running[id] = nil
                library.append("\(name) exited (\(status)).")
            }
        }

        let process: Process
        switch game.kind {
        case .ps5Native:
            var env = ProcessInfo.processInfo.environment
            env["ROSETTA_ADVERTISE_AVX"] = "1"
            if game.settings.metalHUD { env["MTL_HUD_ENABLED"] = "1" }
            if !library.ps5.vulkanICD.isEmpty { env["VK_ICD_FILENAMES"] = library.ps5.vulkanICD }
            for (k, v) in Shell.parseEnv(game.settings.extraEnv) { env[k] = v }
            // Mach-O is x86-64, so force Rosetta.
            process = try Shell.launchDetached(Shell.arch, ["-x86_64", exe.path] + args,
                                               environment: env, directory: workDir, logFile: logFile,
                                               onExit: onExit)
        case .windows, .ps5Windows:
            guard let bottle = library.bottle(id: game.bottleID) ?? library.defaultBottle else {
                throw ShellError(message: "Create a bottle first (Bottles tab).")
            }
            guard let engine = library.engine(id: bottle.engineID) else {
                throw ShellError(message: "The bottle's engine (\(bottle.engineID)) is missing.")
            }
            if game.kind == .windows {
                try prepareBackend(game.settings.backend, bottle: bottle, engine: engine)
            }
            try await setRetina(game.settings.retinaMode, bottle: bottle, engine: engine, library: library)
            let env = gameEnvironment(game: game, bottle: bottle, engine: engine)
            process = try Shell.launchDetached(URL(fileURLWithPath: engine.wineBinary), [exe.path] + args,
                                               environment: env, directory: workDir, logFile: logFile,
                                               onExit: onExit)
        }

        library.running[game.id] = process
        if let i = library.games.firstIndex(where: { $0.id == game.id }) {
            library.games[i].lastPlayed = Date()
        }
        library.append("Launched \(game.name). Log: \(logFile.path)")
    }

    @MainActor
    static func stop(_ game: Game, library: Library) async {
        library.running[game.id]?.terminate()
        if game.kind != .ps5Native, let bottle = library.bottle(id: game.bottleID) ?? library.defaultBottle,
           let engine = library.engine(id: bottle.engineID) {
            await killAll(bottle: bottle, engine: engine)
        }
        library.running[game.id] = nil
    }
}
