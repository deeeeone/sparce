import Foundation

/// Turns a PS5 title folder into a Mac (or Windows-through-Wine) game using AnyPS5's relinker.
///
/// Input: a folder the user dumped from their own console, laid out like `app0/`:
///   eboot.bin  (must be a decrypted ELF; Sparce never decrypts anything)
///   sce_module/ (bundled ELF modules)
///   ...game resources
///
/// Output (in ~/Library/Application Support/Sparce/PS5/<title>/):
///   game (macOS Mach-O) or app.exe (Windows)
///   libs/*.prx
///   app0/  (copy of the input folder)
enum PS5Target: String, CaseIterable, Identifiable {
    case macNative
    case windowsViaWine

    var id: String { rawValue }
    var title: String {
        switch self {
        case .macNative: return "macOS native (Rosetta)"
        case .windowsViaWine: return "Windows build through Wine"
        }
    }
}

struct PS5Job {
    var title: String
    var source: URL
    var target: PS5Target
    var bottleID: UUID?
}

enum PS5Porter {
    static let elfMagic: [UInt8] = [0x7F, 0x45, 0x4C, 0x46]

    static func isELF(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let bytes = (try? handle.read(upToCount: 4)) ?? Data()
        return Array(bytes) == elfMagic
    }

    static func moduleDir(in folder: URL) -> URL? {
        for name in ["sce_module", "sce_modules", "prx"] {
            let dir = folder.appendingPathComponent(name)
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue { return dir }
        }
        return nil
    }

    static func outputFolder(for title: String) -> URL {
        Paths.ps5.appendingPathComponent(title.slug.isEmpty ? "title" : title.slug, isDirectory: true)
    }

    /// Runs the whole port and returns the new library entry.
    static func port(_ job: PS5Job, settings: PS5Settings, library: Library) async throws -> Game {
        let fm = FileManager.default
        let relinker = URL(fileURLWithPath: settings.relinkerPath)
        guard fm.isExecutableFile(atPath: relinker.path) else {
            throw ShellError(message: "Set the path to AnyPS5's relinker first (or build it from the PS5 Porter tab).")
        }
        let libsPath = job.target == .macNative ? settings.macLibsDir : settings.windowsLibsDir
        guard !libsPath.isEmpty, fm.fileExists(atPath: libsPath) else {
            throw ShellError(message: job.target == .macNative
                ? "Set the folder of macOS-built AnyPS5 runtime libraries (libs/*.prx)."
                : "Set the folder of Windows AnyPS5 runtime libraries (from an AnyPS5 release).")
        }

        // 1. Find the executable.
        var eboot = job.source.appendingPathComponent("eboot.bin")
        guard fm.fileExists(atPath: eboot.path) else {
            throw ShellError(message: "No eboot.bin in \(job.source.lastPathComponent).")
        }

        let out = outputFolder(for: job.title)
        try? fm.removeItem(at: out)
        try fm.createDirectory(at: out, withIntermediateDirectories: true)

        if !isELF(eboot) {
            // Decrypted SELF containers can be unwrapped with AnyPS5's own tool.
            let unwrap = URL(fileURLWithPath: settings.sourceCheckout).appendingPathComponent("tools/unwrap_self.py")
            guard !settings.sourceCheckout.isEmpty, fm.fileExists(atPath: unwrap.path) else {
                throw ShellError(message: "eboot.bin isn't a plain ELF. If it's a decrypted SELF, set the AnyPS5 source folder so Sparce can unwrap it. Encrypted files can't be used.")
            }
            let unwrapped = out.appendingPathComponent("eboot.elf")
            library.append("Unwrapping SELF container…")
            try await Shell.check(Shell.env, ["python3", unwrap.path, eboot.path, unwrapped.path]) { library.append($0) }
            eboot = unwrapped
        }

        // 2. Copy resources and runtime libraries.
        library.append("Copying game files…")
        try await Shell.check(Shell.ditto, [job.source.path, out.appendingPathComponent("app0").path]) { library.append($0) }
        try await Shell.check(Shell.ditto, [libsPath, out.appendingPathComponent("libs").path]) { library.append($0) }

        // 3. Relink.
        let exeName = job.target == .macNative ? "game" : "app.exe"
        let output = out.appendingPathComponent(exeName)
        var args: [String] = []
        switch job.target {
        case .macNative: args += ["--macos", "--to-rosetta"]
        case .windowsViaWine: args += ["--windows", "--to-rosetta"]
        }
        if let modules = moduleDir(in: job.source) {
            args += ["--sce-module-path", modules.path]
        }
        args += [eboot.path, output.path]

        library.append("relinker \(args.joined(separator: " "))")
        let code = try await Shell.run(relinker, args, directory: out) { library.append($0) }
        switch code {
        case 0: break
        case 1: throw ShellError(message: "relinker rejected the arguments (exit 1).")
        default: throw ShellError(message: "Conversion failed (exit \(code)). See the log for details.")
        }
        guard fm.fileExists(atPath: output.path) else {
            throw ShellError(message: "relinker finished but no \(exeName) was produced.")
        }

        var game = Game(name: job.title,
                        kind: job.target == .macNative ? .ps5Native : .ps5Windows,
                        executable: output.path,
                        workingDirectory: out.path,
                        bottleID: job.bottleID)
        game.settings.advertiseAVX = true
        return game
    }

    // MARK: Building AnyPS5's relinker

    static let checkout = Paths.support.appendingPathComponent("AnyPS5", isDirectory: true)

    /// Clones AnyPS5 and builds the relinker-only target (supported on Apple silicon).
    /// Needs Xcode command line tools, CMake and Ninja (`brew install cmake ninja`).
    static func buildRelinker(library: Library) async throws -> URL {
        let fm = FileManager.default
        let env = buildEnvironment()
        if !fm.fileExists(atPath: checkout.appendingPathComponent(".git").path) {
            try await Shell.check(Shell.env, ["git", "clone", "--recursive",
                                              "https://github.com/boykopovar/AnyPS5.git", checkout.path],
                                  environment: env) { library.append($0) }
        } else {
            try await Shell.check(Shell.env, ["git", "-C", checkout.path, "pull", "--ff-only"],
                                  environment: env) { library.append($0) }
        }
        try await Shell.check(Shell.env, ["cmake", "-S", ".", "-B", "build-relinker", "-G", "Ninja",
                                          "-DCMAKE_BUILD_TYPE=Release", "-DANYPS5_RELINKER_ONLY=ON"],
                              environment: env, directory: checkout) { library.append($0) }
        try await Shell.check(Shell.env, ["cmake", "--build", "build-relinker", "--parallel"],
                              environment: env, directory: checkout) { library.append($0) }
        let binary = checkout.appendingPathComponent("build-relinker/core/relinker/relinker")
        guard fm.isExecutableFile(atPath: binary.path) else {
            throw ShellError(message: "Build finished but the relinker binary wasn't found.")
        }
        return binary
    }

    /// GUI apps don't get the shell PATH, so add Homebrew's locations.
    static func buildEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let extra = "/opt/homebrew/bin:/usr/local/bin"
        env["PATH"] = extra + ":" + (env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")
        return env
    }

    /// Looks for a MoltenVK ICD from the LunarG Vulkan SDK (universal, so it loads under Rosetta).
    static func detectVulkanICD() -> String? {
        let fm = FileManager.default
        let candidates = [
            "/usr/local/share/vulkan/icd.d/MoltenVK_icd.json",
        ]
        if let hit = candidates.first(where: { fm.fileExists(atPath: $0) }) { return hit }
        let sdkRoot = fm.homeDirectoryForCurrentUser.appendingPathComponent("VulkanSDK")
        let versions = ((try? fm.contentsOfDirectory(atPath: sdkRoot.path)) ?? []).sorted(by: >)
        for v in versions {
            let p = sdkRoot.appendingPathComponent(v).appendingPathComponent("macOS/share/vulkan/icd.d/MoltenVK_icd.json").path
            if fm.fileExists(atPath: p) { return p }
        }
        return nil
    }
}
