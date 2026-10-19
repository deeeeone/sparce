import SwiftUI
import AppKit

enum Theme {
    static let background = LinearGradient(
        colors: [Color(red: 0.07, green: 0.07, blue: 0.10), Color(red: 0.10, green: 0.08, blue: 0.16)],
        startPoint: .top, endPoint: .bottom)
    static let card = Color.white.opacity(0.06)
    static let cardHover = Color.white.opacity(0.10)
    static let accent = Color(red: 0.55, green: 0.42, blue: 1.0)

    static func color(for rating: CompatRating) -> Color {
        switch rating {
        case .native: return .blue
        case .works: return .green
        case .issues: return .orange
        case .blocked: return .red
        case .unknown: return .gray
        }
    }
}

struct CompatBadge: View {
    let rating: CompatRating
    var compact = false

    var body: some View {
        Group {
            if compact {
                Image(systemName: rating.symbol)
            } else {
                Label(rating.title, systemImage: rating.symbol)
            }
        }
            .font(.caption.weight(.semibold))
            .padding(.horizontal, compact ? 6 : 8)
            .padding(.vertical, 4)
            .foregroundStyle(.white)
            .background(Theme.color(for: rating).opacity(0.85), in: Capsule())
            .help(rating.title)
    }
}

struct StoreTag: View {
    let game: Game

    var body: some View {
        Text(label)
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 4))
            .foregroundStyle(.white)
    }

    private var label: String {
        switch game.store {
        case .epic: return "EPIC"
        case .gog: return "GOG"
        case nil: return game.kind == .ps5Native || game.kind == .ps5Windows ? "PS5" : "LOCAL"
        }
    }
}

/// Cover art with a generated fallback.
struct GameArt: View {
    let game: Game

    var body: some View {
        ZStack {
            placeholder
            if let s = game.artURL, let url = URL(string: s) {
                AsyncImage(url: url, transaction: Transaction(animation: .easeOut(duration: 0.25))) { phase in
                    if let image = phase.image {
                        image.resizable().aspectRatio(contentMode: .fill)
                    }
                }
            }
        }
        .clipped()
    }

    private var placeholder: some View {
        // Stable per title (hashValue changes every launch).
        let seed = game.name.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
        let hue = Double(seed % 360) / 360
        return ZStack {
            LinearGradient(colors: [Color(hue: hue, saturation: 0.6, brightness: 0.5),
                                    Color(hue: (hue + 0.12).truncatingRemainder(dividingBy: 1), saturation: 0.7, brightness: 0.25)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            Text(initials)
                .font(.system(size: 34, weight: .heavy, design: .rounded))
                .foregroundStyle(.white.opacity(0.85))
        }
    }

    private var initials: String {
        let words = game.name.split(separator: " ").prefix(2)
        return words.compactMap { $0.first.map(String.init) }.joined().uppercased()
    }
}

/// Play / install / stop logic shared by cards and the detail view.
@MainActor
enum GameActions {
    static func primary(_ game: Game, library: Library) {
        if library.running[game.id] != nil {
            Task { await WineRunner.stop(game, library: library) }
        } else if !game.isInstalled {
            install(game, library: library)
        } else {
            Task {
                do { try await WineRunner.launch(game, library: library) }
                catch { library.errorMessage = error.localizedDescription }
            }
        }
    }

    static func install(_ game: Game, library: Library) {
        guard library.progress[game.id] == nil else { return }
        Task {
            library.append("Installing \(game.name)…")
            do {
                try await Stores.install(game, library: library)
                library.append("✓ Installed \(game.name)")
            } catch {
                library.append("✗ \(game.name): \(error.localizedDescription)")
                library.errorMessage = error.localizedDescription
            }
        }
    }

    static func uninstall(_ game: Game, library: Library) {
        let alert = NSAlert()
        alert.messageText = "Uninstall \(game.name)?"
        alert.informativeText = "The game files will be deleted. You can reinstall it from your library any time."
        alert.addButton(withTitle: "Uninstall")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task {
            do { try await Stores.uninstall(game, library: library) }
            catch { library.errorMessage = error.localizedDescription }
        }
    }

    static func primaryTitle(_ game: Game, library: Library) -> (String, String) {
        if library.running[game.id] != nil { return ("Stop", "stop.fill") }
        if library.progress[game.id] != nil { return ("Installing", "arrow.down.circle") }
        if !game.isInstalled { return ("Install", "arrow.down.circle.fill") }
        return ("Play", "play.fill")
    }
}
