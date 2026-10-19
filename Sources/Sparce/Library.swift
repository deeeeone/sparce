import Foundation
import AppKit

/// App state: games, bottles, engines. Saved to library.json.
@MainActor
final class Library: ObservableObject {
    @Published var games: [Game] = [] { didSet { save() } }
    @Published var bottles: [Bottle] = [] { didSet { save() } }
    @Published var customEngines: [Engine] = [] { didSet { save() } }
    @Published var ps5 = PS5Settings() { didSet { save() } }
    @Published var defaultBottleID: UUID? { didSet { save() } }

    @Published private(set) var installedEngines: [Engine] = []
    @Published var log: [String] = []
    @Published var busy: String?
    @Published var running: [UUID: Process] = [:]
    @Published var errorMessage: String?

    private var loading = true

    init() {
        Paths.ensureAll()
        if let data = try? Data(contentsOf: Paths.libraryFile),
           let file = try? JSONDecoder().decode(LibraryFile.self, from: data) {
            games = file.games
            bottles = file.bottles
            customEngines = file.customEngines
            ps5 = file.ps5
            defaultBottleID = file.defaultBottleID
        }
        loading = false
        refreshEngines()
    }

    private func save() {
        guard !loading else { return }
        let file = LibraryFile(games: games, bottles: bottles, customEngines: customEngines,
                               ps5: ps5, defaultBottleID: defaultBottleID)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(file) {
            try? data.write(to: Paths.libraryFile, options: .atomic)
        }
    }

    // MARK: Engines

    var engines: [Engine] { installedEngines + customEngines }

    func engine(id: String) -> Engine? { engines.first { $0.id == id } }

    func refreshEngines() {
        let fm = FileManager.default
        let dirs = (try? fm.contentsOfDirectory(at: Paths.engines, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        installedEngines = dirs.compactMap { dir in
            guard let wine = FileSearch.wineBinary(under: dir) else { return nil }
            return Engine(id: dir.lastPathComponent, name: dir.lastPathComponent, root: dir.path, wineBinary: wine.path)
        }.sorted { $0.name < $1.name }
    }

    // MARK: Bottles

    func bottle(id: UUID?) -> Bottle? {
        guard let id else { return nil }
        return bottles.first { $0.id == id }
    }

    var defaultBottle: Bottle? { bottle(id: defaultBottleID) ?? bottles.first }

    // MARK: Logging and tasks

    nonisolated func append(_ line: String) {
        Task { @MainActor in
            self.log.append(line)
            if self.log.count > 4000 { self.log.removeFirst(self.log.count - 4000) }
        }
    }

    /// Runs a long task with a status label and error reporting.
    func perform(_ label: String, _ work: @escaping @MainActor () async throws -> Void) {
        guard busy == nil else { return }
        busy = label
        append("▶︎ \(label)")
        Task {
            do {
                try await work()
                append("✓ \(label)")
            } catch {
                append("✗ \(label): \(error.localizedDescription)")
                errorMessage = error.localizedDescription
            }
            busy = nil
        }
    }

    func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
