import SwiftUI
import AppKit

enum LibraryFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case installed = "Installed"
    case playable = "Plays on Mac"
    case epic = "Epic"
    case gog = "GOG"
    case local = "Local"
    var id: String { rawValue }
}

@MainActor
struct LibraryView: View {
    @EnvironmentObject var library: Library
    @ObservedObject private var compat = Compatibility.shared
    @State private var filter: LibraryFilter = .all
    @State private var search = ""
    @State private var detail: Game?

    private let columns = [GridItem(.adaptive(minimum: 230, maximum: 320), spacing: 18)]

    private var filtered: [Game] {
        library.games
            .filter { game in
                switch filter {
                case .all: return true
                case .installed: return game.isInstalled
                case .playable:
                    let r = compat.info(for: game).rating
                    return r == .native || r == .works
                case .epic: return game.store == .epic
                case .gog: return game.store == .gog
                case .local: return game.store == nil
                }
            }
            .filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }
            .sorted { a, b in
                if a.isInstalled != b.isInstalled { return a.isInstalled }
                return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }
    }

    private var recent: [Game] {
        library.games.filter { $0.lastPlayed != nil && $0.isInstalled }
            .sorted { ($0.lastPlayed ?? .distantPast) > ($1.lastPlayed ?? .distantPast) }
    }

    private var featured: Game? {
        recent.first ?? library.games.first(where: { $0.isInstalled && $0.artURL != nil })
            ?? library.games.first(where: { $0.artURL != nil })
    }

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            if library.games.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 28) {
                        if search.isEmpty, filter == .all, let featured {
                            HeroBanner(game: featured) { detail = featured }
                        }
                        if search.isEmpty, filter == .all, recent.count > 1 {
                            shelf("Continue playing", games: Array(recent.prefix(10)))
                        }
                        filterBar
                        LazyVGrid(columns: columns, spacing: 22) {
                            ForEach(filtered) { game in
                                GameTile(game: game) { detail = game }
                            }
                        }
                        if filtered.isEmpty {
                            Text("Nothing here yet.").foregroundStyle(.secondary).frame(maxWidth: .infinity)
                        }
                    }
                    .padding(24)
                }
            }
        }
        .navigationTitle("Library")
        .searchable(text: $search, placement: .toolbar, prompt: "Search games")
        .toolbar {
            ToolbarItemGroup {
                if library.epicSignedIn || library.gogSignedIn {
                    Button {
                        library.perform("Syncing stores") { try await Stores.sync(library: library) }
                    } label: { Label("Sync", systemImage: "arrow.clockwise") }
                    .disabled(library.busy != nil)
                    .help("Refresh Epic and GOG libraries")
                }
                Menu {
                    Button("Add Windows game (.exe)…") { addWindowsGame() }
                    Button("Add Mac game (.app)…") { addMacGame() }
                    Divider()
                    Button("Connect Epic or GOG…") { library.section = .stores }
                    Button("Port a PS5 title…") { library.section = .ps5 }
                } label: { Label("Add", systemImage: "plus") }
            }
        }
        .sheet(item: $detail) { game in
            GameDetailView(gameID: game.id)
        }
        .task { await compat.load() }
        .preferredColorScheme(.dark)
    }

    private var filterBar: some View {
        HStack(spacing: 8) {
            ForEach(LibraryFilter.allCases) { f in
                Button { withAnimation(.snappy) { filter = f } } label: {
                    Text(f.rawValue)
                        .font(.callout.weight(.medium))
                        .padding(.horizontal, 14).padding(.vertical, 7)
                        .background(filter == f ? Theme.accent : Theme.card, in: Capsule())
                        .foregroundStyle(filter == f ? .white : .primary)
                }
                .buttonStyle(.plain)
            }
            Spacer()
            Text("\(filtered.count) games").font(.callout).foregroundStyle(.secondary)
        }
    }

    private func shelf(_ title: String, games: [Game]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.title3.weight(.bold))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 16) {
                    ForEach(games) { game in
                        GameTile(game: game) { detail = game }.frame(width: 240)
                    }
                }
                .padding(.vertical, 6)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 22) {
            Image(systemName: "gamecontroller.fill")
                .font(.system(size: 64))
                .foregroundStyle(Theme.accent)
            Text("Your library is empty").font(.largeTitle.weight(.bold))
            Text("Connect Epic Games or GOG to bring in the games you own, or add any Windows or Mac game you already have.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 440)
            HStack(spacing: 12) {
                Button { library.section = .stores } label: {
                    Label("Connect a store", systemImage: "link").padding(.horizontal, 8)
                }
                .buttonStyle(.borderedProminent).tint(Theme.accent).controlSize(.large)
                Button("Add a game…") { addWindowsGame() }.controlSize(.large)
            }
        }
        .padding(40)
    }

    private func addWindowsGame() {
        guard let exe = FilePicker.file(types: ["exe"], prompt: "Add") else { return }
        guard library.defaultBottle != nil else {
            library.errorMessage = "Create a bottle in the Bottles tab first."
            return
        }
        let game = Game(name: exe.deletingPathExtension().lastPathComponent, kind: .windows,
                        executable: exe.path, bottleID: library.defaultBottle?.id)
        library.games.append(game)
        detail = game
    }

    private func addMacGame() {
        guard let app = FilePicker.file(types: ["app"], prompt: "Add") else { return }
        let game = Game(name: app.deletingPathExtension().lastPathComponent, kind: .macApp, executable: app.path)
        library.games.append(game)
    }
}

// MARK: - Hero banner

@MainActor
struct HeroBanner: View {
    @EnvironmentObject var library: Library
    @ObservedObject private var compat = Compatibility.shared
    let game: Game
    let open: () -> Void

    var body: some View {
        let info = compat.info(for: game)
        let action = GameActions.primaryTitle(game, library: library)
        ZStack(alignment: .bottomLeading) {
            GameArt(game: game)
                .frame(height: 300)
                .frame(maxWidth: .infinity)
                .overlay(LinearGradient(colors: [.clear, .black.opacity(0.85)], startPoint: .center, endPoint: .bottom))
                .overlay(LinearGradient(colors: [.black.opacity(0.6), .clear], startPoint: .leading, endPoint: .center))

            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    StoreTag(game: game)
                    CompatBadge(rating: info.rating)
                }
                Text(game.name)
                    .font(.system(size: 38, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                if let last = game.lastPlayed {
                    Text("Last played \(last.formatted(.relative(presentation: .named)))")
                        .font(.callout).foregroundStyle(.white.opacity(0.7))
                }
                HStack(spacing: 12) {
                    Button { GameActions.primary(game, library: library) } label: {
                        Label(action.0, systemImage: action.1)
                            .font(.headline)
                            .padding(.horizontal, 22).padding(.vertical, 10)
                    }
                    .buttonStyle(.plain)
                    .background(Theme.accent, in: Capsule())
                    .foregroundStyle(.white)
                    .disabled(library.progress[game.id] != nil)

                    Button("Details", action: open)
                        .buttonStyle(.plain)
                        .padding(.horizontal, 18).padding(.vertical, 10)
                        .background(.white.opacity(0.15), in: Capsule())
                        .foregroundStyle(.white)
                }
            }
            .padding(28)
        }
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .shadow(color: .black.opacity(0.4), radius: 20, y: 10)
    }
}

// MARK: - Tile

@MainActor
struct GameTile: View {
    @EnvironmentObject var library: Library
    @ObservedObject private var compat = Compatibility.shared
    let game: Game
    let open: () -> Void
    @State private var hovering = false

    var body: some View {
        let info = compat.info(for: game)
        let progress = library.progress[game.id]
        let running = library.running[game.id] != nil

        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                GameArt(game: game)
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .saturation(game.isInstalled ? 1 : 0.55)

                if hovering || running {
                    Color.black.opacity(0.35)
                    Button { GameActions.primary(game, library: library) } label: {
                        Image(systemName: GameActions.primaryTitle(game, library: library).1)
                            .font(.system(size: 22, weight: .bold))
                            .frame(width: 54, height: 54)
                            .background(running ? Color.red : Theme.accent, in: Circle())
                            .foregroundStyle(.white)
                            .shadow(radius: 8)
                    }
                    .buttonStyle(.plain)
                    .disabled(progress != nil)
                    .transition(.scale.combined(with: .opacity))
                }

                VStack {
                    HStack {
                        StoreTag(game: game)
                        Spacer()
                        CompatBadge(rating: info.rating, compact: true)
                    }
                    Spacer()
                    if let progress {
                        ProgressView(value: progress)
                            .tint(Theme.accent)
                            .padding(6)
                            .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
                    }
                }
                .padding(8)
            }
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(hovering ? 0.35 : 0.08)))
            .shadow(color: .black.opacity(hovering ? 0.5 : 0.2), radius: hovering ? 14 : 6, y: hovering ? 8 : 3)

            HStack {
                Text(game.name).font(.callout.weight(.semibold)).lineLimit(1)
                Spacer()
                if running {
                    Text("Running").font(.caption2.weight(.bold)).foregroundStyle(.green)
                } else if !game.isInstalled {
                    Image(systemName: "icloud.and.arrow.down").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .scaleEffect(hovering ? 1.03 : 1)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: hovering)
        .onHover { hovering = $0 }
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
        .contextMenu {
            Button(GameActions.primaryTitle(game, library: library).0) { GameActions.primary(game, library: library) }
            Button("Details…", action: open)
            if game.isInstalled, let path = game.installPath ?? (game.executable.isEmpty ? nil : game.executable) {
                Button("Show in Finder") { library.reveal(URL(fileURLWithPath: path)) }
            }
            Divider()
            if game.store != nil, game.isInstalled {
                Button("Uninstall…") { GameActions.uninstall(game, library: library) }
            }
            if game.store == nil {
                Button("Remove from Library", role: .destructive) { library.games.removeAll { $0.id == game.id } }
            }
        }
    }
}

@MainActor
struct GameSettingsView: View {
    @EnvironmentObject var library: Library
    @Environment(\.dismiss) private var dismiss
    @State var game: Game

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Game") {
                    TextField("Name", text: $game.name)
                    LabeledContent("Executable") {
                        Text(game.executable).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                    }
                    TextField("Arguments", text: $game.settings.arguments)
                    if game.kind == .windows || game.kind == .ps5Windows {
                        Picker("Bottle", selection: $game.bottleID) {
                            ForEach(library.bottles) { Text($0.name).tag(Optional($0.id)) }
                        }
                    }
                }

                if game.kind == .windows {
                    Section("Graphics") {
                        Picker("Translation layer", selection: $game.settings.backend) {
                            ForEach(GraphicsBackend.allCases) { Text($0.title).tag($0) }
                        }
                        Text(game.settings.backend.blurb).font(.caption).foregroundStyle(.secondary)
                        if game.settings.backend == .d3dmetal {
                            Toggle("DirectX Raytracing (M3 or newer)", isOn: $game.settings.raytracing)
                        }
                        if game.settings.backend == .dxvk {
                            Stepper(value: $game.settings.fpsLimit, in: 0...240, step: 15) {
                                Text(game.settings.fpsLimit == 0 ? "Frame cap: off" : "Frame cap: \(game.settings.fpsLimit) fps")
                            }
                        }
                    }
                }

                Section("Performance") {
                    if game.kind == .windows || game.kind == .ps5Windows {
                        Toggle("MSync (faster thread sync)", isOn: $game.settings.msync)
                        Toggle("Retina mode (sharper, heavier)", isOn: $game.settings.retinaMode)
                        Toggle("Quiet Wine logs", isOn: $game.settings.quietLogs)
                    }
                    Toggle("Report AVX to games (Rosetta)", isOn: $game.settings.advertiseAVX)
                    Toggle("Metal performance HUD", isOn: $game.settings.metalHUD)
                }

                Section("Advanced") {
                    TextEditor(text: $game.settings.extraEnv)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 60)
                    Text("Extra environment variables, one KEY=VALUE per line.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") {
                    if let i = library.games.firstIndex(where: { $0.id == game.id }) {
                        library.games[i] = game
                    }
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 520, height: 620)
    }
}
