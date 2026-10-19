import SwiftUI
import AppKit

@MainActor
struct GameDetailView: View {
    @EnvironmentObject var library: Library
    @ObservedObject private var compat = Compatibility.shared
    @Environment(\.dismiss) private var dismiss
    let gameID: UUID
    @State private var showSettings = false

    var body: some View {
        if let game = library.game(id: gameID) {
            content(game)
        } else {
            Text("Game removed.").padding(40)
        }
    }

    private func content(_ game: Game) -> some View {
        let info = compat.info(for: game)
        let action = GameActions.primaryTitle(game, library: library)
        let progress = library.progress[game.id]

        return VStack(spacing: 0) {
            // Header
            ZStack(alignment: .bottomLeading) {
                GameArt(game: game)
                    .frame(height: 240)
                    .frame(maxWidth: .infinity)
                    .overlay(LinearGradient(colors: [.clear, Color(red: 0.08, green: 0.07, blue: 0.12)],
                                            startPoint: .center, endPoint: .bottom))
                VStack(alignment: .leading, spacing: 8) {
                    HStack { StoreTag(game: game); CompatBadge(rating: info.rating) }
                    Text(game.name)
                        .font(.system(size: 30, weight: .heavy, design: .rounded))
                        .foregroundStyle(.white)
                }
                .padding(24)
            }
            .overlay(alignment: .topTrailing) {
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.headline)
                        .frame(width: 30, height: 30)
                        .background(.black.opacity(0.5), in: Circle())
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .padding(14)
                .keyboardShortcut(.cancelAction)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Actions
                    HStack(spacing: 12) {
                        Button { GameActions.primary(game, library: library) } label: {
                            Label(action.0, systemImage: action.1)
                                .font(.headline)
                                .frame(minWidth: 140)
                                .padding(.vertical, 10)
                        }
                        .buttonStyle(.plain)
                        .background(library.running[game.id] != nil ? Color.red : Theme.accent, in: Capsule())
                        .foregroundStyle(.white)
                        .disabled(progress != nil)

                        if let progress {
                            VStack(alignment: .leading) {
                                ProgressView(value: progress).tint(Theme.accent)
                                Text("\(Int(progress * 100))% downloaded").font(.caption).foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: 220)
                        }

                        Spacer()

                        if game.kind == .windows || game.kind == .ps5Windows {
                            Button { showSettings = true } label: { Label("Settings", systemImage: "slider.horizontal.3") }
                        }
                        Menu {
                            if game.isInstalled, let path = game.installPath ?? (game.executable.isEmpty ? nil : game.executable) {
                                Button("Show in Finder") { library.reveal(URL(fileURLWithPath: path)) }
                            }
                            Button("Open Log") { NSWorkspace.shared.open(Paths.logs) }
                            if let url = Compatibility.lookupURL(for: game.name) {
                                Button("Look up on AppleGamingWiki") { NSWorkspace.shared.open(url) }
                            }
                            Divider()
                            if game.store != nil, game.isInstalled {
                                Button("Uninstall…") { GameActions.uninstall(game, library: library) }
                            }
                            if game.store == nil {
                                Button("Remove from Library", role: .destructive) {
                                    library.games.removeAll { $0.id == game.id }
                                    dismiss()
                                }
                            }
                        } label: { Image(systemName: "ellipsis") }
                        .menuStyle(.borderlessButton)
                        .frame(width: 34)
                    }

                    if info.rating == .blocked {
                        Label("This game probably won't run on a Mac. Cloud gaming (GeForce NOW, Xbox Cloud) is the usual way to play it.",
                              systemImage: "exclamationmark.octagon")
                            .font(.callout)
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.red.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
                    }

                    if game.hasMacVersion == true, game.kind != .macApp {
                        Toggle(isOn: $library.preferMacVersions) {
                            Text("A Mac version exists. Install it instead of the Windows one")
                        }
                        .toggleStyle(.switch)
                    }

                    compatCard(game, info)
                }
                .padding(24)
            }
        }
        .frame(width: 720, height: 620)
        .background(Color(red: 0.08, green: 0.07, blue: 0.12))
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showSettings) { GameSettingsView(game: game) }
    }

    private func compatCard(_ game: Game, _ info: CompatInfo) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Mac compatibility").font(.headline)
                Spacer()
                Text(info.source).font(.caption).foregroundStyle(.secondary)
            }

            HStack(spacing: 14) {
                Image(systemName: info.rating.symbol)
                    .font(.system(size: 30))
                    .foregroundStyle(Theme.color(for: info.rating))
                VStack(alignment: .leading, spacing: 4) {
                    Text(info.rating.title).font(.title3.weight(.bold))
                    if let backend = info.recommendedBackend {
                        Text("Best with \(backend.title)").font(.callout).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if let backend = info.recommendedBackend, game.settings.backend != backend, game.kind == .windows {
                    Button("Use \(backend.title)") {
                        library.update(game.id) { $0.settings.backend = backend }
                    }
                }
            }

            ForEach(info.notes, id: \.self) { note in
                Label(note, systemImage: "info.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("How did it run for you?").font(.callout.weight(.medium))
                HStack(spacing: 8) {
                    ForEach([CompatRating.works, .issues, .blocked]) { r in
                        Button {
                            library.update(game.id) { $0.userRating = $0.userRating == r ? nil : r }
                        } label: {
                            Label(r == .blocked ? "Doesn't run" : r.title, systemImage: r.symbol)
                                .padding(.horizontal, 10).padding(.vertical, 6)
                                .background(game.userRating == r ? Theme.color(for: r).opacity(0.8) : Theme.card,
                                            in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
                if game.kind == .windows {
                    Text("Current graphics layer: \(game.settings.backend.title)")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(18)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 14))
    }
}
