import SwiftUI
import AppKit

@MainActor
struct LibraryView: View {
    @EnvironmentObject var library: Library
    @State private var editing: Game?

    private let columns = [GridItem(.adaptive(minimum: 220), spacing: 16)]

    var body: some View {
        Group {
            if library.games.isEmpty {
                ContentUnavailableView {
                    Label("No games yet", systemImage: "gamecontroller")
                } description: {
                    Text("Add a Windows .exe, install Steam in a bottle, or port a PS5 title.")
                } actions: {
                    Button("Add Windows Game…") { addGame() }
                        .buttonStyle(.borderedProminent)
                }
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(library.games) { game in
                            GameCard(game: game, onEdit: { editing = game })
                        }
                    }
                    .padding(20)
                }
            }
        }
        .navigationTitle("Library")
        .toolbar {
            Button { addGame() } label: { Label("Add Game", systemImage: "plus") }
        }
        .sheet(item: $editing) { game in
            GameSettingsView(game: game)
        }
    }

    private func addGame() {
        guard let exe = FilePicker.file(types: ["exe"], prompt: "Add") else { return }
        if library.bottles.isEmpty {
            library.errorMessage = "Create a bottle in the Bottles tab first."
            return
        }
        let game = Game(name: exe.deletingPathExtension().lastPathComponent,
                        kind: .windows,
                        executable: exe.path,
                        bottleID: library.defaultBottle?.id)
        library.games.append(game)
        editing = game
    }
}

@MainActor
struct GameCard: View {
    @EnvironmentObject var library: Library
    let game: Game
    let onEdit: () -> Void

    private var isRunning: Bool { library.running[game.id] != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(LinearGradient(colors: [.accentColor.opacity(0.7), .purple.opacity(0.6)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                Text(String(game.name.prefix(1)).uppercased())
                    .font(.system(size: 48, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
            }
            .frame(height: 120)

            Text(game.name).font(.headline).lineLimit(1)
            Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)

            HStack {
                Button {
                    if isRunning {
                        Task { await WineRunner.stop(game, library: library) }
                    } else {
                        Task {
                            do { try await WineRunner.launch(game, library: library) }
                            catch { library.errorMessage = error.localizedDescription }
                        }
                    }
                } label: {
                    Label(isRunning ? "Stop" : "Play", systemImage: isRunning ? "stop.fill" : "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(isRunning ? .red : .accentColor)

                Button(action: onEdit) { Image(systemName: "slider.horizontal.3") }
                    .help("Game settings")
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 14))
        .contextMenu {
            Button("Show in Finder") { library.reveal(URL(fileURLWithPath: game.executable)) }
            Button("Open Log") {
                library.reveal(Paths.logs.appendingPathComponent("\(game.name.slug).log"))
            }
            Divider()
            Button("Remove from Library", role: .destructive) {
                library.games.removeAll { $0.id == game.id }
            }
        }
    }

    private var subtitle: String {
        switch game.kind {
        case .windows: return game.settings.backend.title
        case .ps5Windows: return "PS5 port · Windows via Wine"
        case .ps5Native: return "PS5 port · macOS native"
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
                    if game.kind != .ps5Native {
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
                    if game.kind != .ps5Native {
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
