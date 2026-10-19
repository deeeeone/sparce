import SwiftUI
import AppKit

@MainActor
struct BottlesView: View {
    @EnvironmentObject var library: Library
    @State private var newName = "Games"
    @State private var newEngineID = ""

    var body: some View {
        Form {
            Section("New bottle") {
                if library.engines.isEmpty {
                    Text("Install a Wine engine in Components first.").foregroundStyle(.secondary)
                } else {
                    TextField("Name", text: $newName)
                    Picker("Engine", selection: $newEngineID) {
                        ForEach(library.engines) { Text($0.name).tag($0.id) }
                    }
                    Button("Create Bottle") { create() }
                        .disabled(newName.isEmpty || library.engine(id: newEngineID) == nil || library.busy != nil)
                }
            }

            ForEach(library.bottles) { bottle in
                BottleRow(bottle: bottle)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Bottles")
        .onAppear {
            if library.engine(id: newEngineID) == nil {
                newEngineID = library.engines.first(where: { $0.hasD3DMetal })?.id ?? library.engines.first?.id ?? ""
            }
        }
    }

    private func create() {
        guard let engine = library.engine(id: newEngineID) else { return }
        let bottle = Bottle(name: newName, engineID: engine.id)
        library.perform("Creating bottle \(bottle.name)") {
            try await WineRunner.createBottle(bottle, engine: engine, library: library)
            library.bottles.append(bottle)
            if library.defaultBottleID == nil { library.defaultBottleID = bottle.id }
        }
    }
}

@MainActor
struct BottleRow: View {
    @EnvironmentObject var library: Library
    let bottle: Bottle

    private var engine: Engine? { library.engine(id: bottle.engineID) }

    var body: some View {
        Section {
            LabeledContent("Engine", value: engine?.name ?? "Missing (\(bottle.engineID))")
            LabeledContent("D3DMetal", value: engine?.hasD3DMetal == true ? "Yes" : "No")
            Toggle("Default bottle for new games", isOn: Binding(
                get: { library.defaultBottleID == bottle.id },
                set: { if $0 { library.defaultBottleID = bottle.id } }))

            HStack {
                Button("Install Steam") { installSteam() }
                Button("Run .exe…") { runExe() }
                Button("Wine Config") { tool("winecfg") }
                Button("Open C: Drive") { library.reveal(bottle.driveC) }
            }
            .disabled(engine == nil || library.busy != nil)

            HStack {
                Button("Force Quit Everything") {
                    if let engine { Task { await WineRunner.killAll(bottle: bottle, engine: engine) } }
                }
                Spacer()
                Button("Delete Bottle", role: .destructive) { delete() }
            }
        } header: {
            Text(bottle.name)
        }
    }

    private func installSteam() {
        guard let engine else { return }
        library.perform("Installing Steam in \(bottle.name)") {
            try await Components.installSteam(bottle: bottle, engine: engine, library: library)
            let exe = Components.steamExecutable(in: bottle)
            if !library.games.contains(where: { $0.executable == exe.path }) {
                library.games.append(Game(name: "Steam", kind: .windows, executable: exe.path, bottleID: bottle.id))
            }
        }
    }

    private func runExe() {
        guard let engine, let exe = FilePicker.file(types: ["exe", "msi"], prompt: "Run") else { return }
        library.perform("Running \(exe.lastPathComponent)") {
            let args = exe.pathExtension.lowercased() == "msi" ? ["msiexec", "/i", exe.path] : [exe.path]
            try await WineRunner.wine(args, bottle: bottle, engine: engine, library: library)
        }
    }

    private func tool(_ name: String) {
        guard let engine else { return }
        Task { try? await WineRunner.wine([name], bottle: bottle, engine: engine, library: library) }
    }

    private func delete() {
        let alert = NSAlert()
        alert.messageText = "Delete \(bottle.name)?"
        alert.informativeText = "This deletes everything installed in it, including saves stored inside the bottle."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .critical
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        if let engine { Task { await WineRunner.killAll(bottle: bottle, engine: engine) } }
        try? FileManager.default.removeItem(at: bottle.prefixURL)
        library.bottles.removeAll { $0.id == bottle.id }
        if library.defaultBottleID == bottle.id { library.defaultBottleID = library.bottles.first?.id }
    }
}
