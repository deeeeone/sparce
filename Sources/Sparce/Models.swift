import Foundation

/// How Direct3D calls are turned into Metal.
enum GraphicsBackend: String, Codable, CaseIterable, Identifiable {
    case d3dmetal   // Apple's D3DMetal (Game Porting Toolkit). Best for DX11/DX12.
    case dxmt       // Open-source DX10/11 -> Metal.
    case dxvk       // DX9-11 -> Vulkan -> MoltenVK -> Metal. Most compatible, slower.
    case wined3d    // Wine's built-in OpenGL path. Last resort.

    var id: String { rawValue }

    var title: String {
        switch self {
        case .d3dmetal: return "D3DMetal (GPTK)"
        case .dxmt: return "DXMT"
        case .dxvk: return "DXVK + MoltenVK"
        case .wined3d: return "WineD3D (OpenGL)"
        }
    }

    var blurb: String {
        switch self {
        case .d3dmetal: return "Fastest for most DX11/DX12 games. Needs an engine with D3DMetal."
        case .dxmt: return "Open source DX11 to Metal. Needs a CrossOver-based (24+) Wine engine."
        case .dxvk: return "Good for DX9/DX10/DX11 games that break on D3DMetal."
        case .wined3d: return "Slow fallback for very old games."
        }
    }
}

struct GameSettings: Codable, Equatable {
    var backend: GraphicsBackend = .d3dmetal
    /// Mach-semaphore sync (big CPU-side win on macOS).
    var msync: Bool = true
    /// Let Rosetta report AVX/AVX2 to games that require it (macOS 15+).
    var advertiseAVX: Bool = true
    /// Render at full Retina resolution instead of scaled.
    var retinaMode: Bool = false
    /// Apple's Metal performance HUD (fps, GPU time).
    var metalHUD: Bool = false
    /// DirectX Raytracing in D3DMetal (M3 and newer).
    var raytracing: Bool = false
    /// Frame cap (DXVK only). 0 = off. Useful on a fanless MacBook Air.
    var fpsLimit: Int = 0
    /// Silence Wine debug output (faster).
    var quietLogs: Bool = true
    /// Extra environment, one KEY=VALUE per line.
    var extraEnv: String = ""
    /// Command line arguments passed to the game.
    var arguments: String = ""
}

enum GameKind: String, Codable {
    case windows       // .exe run through Wine
    case ps5Windows    // AnyPS5 Windows build run through Wine
    case ps5Native     // AnyPS5 macOS (x86-64 Mach-O) build run under Rosetta
}

struct Game: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var kind: GameKind
    var executable: String
    var workingDirectory: String?
    var bottleID: UUID?
    var settings = GameSettings()
    var lastPlayed: Date?
}

struct Bottle: Codable, Identifiable, Equatable, Hashable {
    var id = UUID()
    var name: String
    var engineID: String
    var created = Date()

    var prefixURL: URL { Paths.bottles.appendingPathComponent(id.uuidString, isDirectory: true) }
    var driveC: URL { prefixURL.appendingPathComponent("drive_c", isDirectory: true) }
}

/// A Wine build Sparce can run games with.
struct Engine: Codable, Identifiable, Equatable, Hashable {
    var id: String
    var name: String
    var root: String
    var wineBinary: String

    var binDir: URL { URL(fileURLWithPath: wineBinary).deletingLastPathComponent() }
    var libDir: URL { binDir.deletingLastPathComponent().appendingPathComponent("lib", isDirectory: true) }
    var wineserver: URL { binDir.appendingPathComponent("wineserver") }

    var hasD3DMetal: Bool {
        FileSearch.first(named: "D3DMetal.framework", under: libDir, maxDepth: 3) != nil
    }

    var unixDir: URL { libDir.appendingPathComponent("wine/x86_64-unix", isDirectory: true) }
    var windowsDir: URL { libDir.appendingPathComponent("wine/x86_64-windows", isDirectory: true) }
}

struct PS5Settings: Codable, Equatable {
    /// Path to AnyPS5's `relinker` binary.
    var relinkerPath: String = ""
    /// Folder of runtime .prx libraries for the target OS (from an AnyPS5 release or build).
    var windowsLibsDir: String = ""
    var macLibsDir: String = ""
    /// AnyPS5 source checkout (for tools/unwrap_self.py). Optional.
    var sourceCheckout: String = ""
    /// MoltenVK ICD json for the native macOS target (must be an x86_64 or universal build).
    var vulkanICD: String = ""
}

struct LibraryFile: Codable {
    var games: [Game] = []
    var bottles: [Bottle] = []
    var customEngines: [Engine] = []
    var ps5 = PS5Settings()
    var defaultBottleID: UUID?
}
