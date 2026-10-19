import SwiftUI
import AppKit

@MainActor
struct ComponentsView: View {
    @EnvironmentObject var library: Library
    @State private var d3dTargetID = ""

    var body: some View {
        Form {
            Section("System") {
                LabeledContent("Rosetta 2") {
                    if Components.rosettaInstalled {
                        Label("Installed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Button("Install Rosetta") {
                            library.perform("Installing Rosetta") { try await Components.installRosetta(library: library) }
                        }
                    }
                }
            }

            Section("Wine engines") {
                ForEach(EngineSource.all) { source in
                    LabeledContent {
                        Button("Download") {
                            library.perform("Installing \(source.name)") {
                                try await Components.install(source, library: library)
                            }
                        }
                        .disabled(library.busy != nil)
                    } label: {
                        Text(source.name)
                        Text(source.detail)
                    }
                }
                Button("Add existing Wine build…") {
                    guard let folder = FilePicker.folder(prompt: "Add") else { return }
                    do { try Components.importEngine(folder: folder, library: library) }
                    catch { library.errorMessage = error.localizedDescription }
                }
                Text("Use this for a CrossOver-based Wine build (24 or newer), which DXMT needs.")
                    .font(.caption).foregroundStyle(.secondary)

                ForEach(library.engines) { engine in
                    LabeledContent(engine.name) {
                        HStack {
                            if engine.hasD3DMetal { Text("D3DMetal").font(.caption).padding(4).background(.green.opacity(0.2), in: Capsule()) }
                            Button("Reveal") { library.reveal(URL(fileURLWithPath: engine.root)) }
                        }
                    }
                }
            }

            Section("D3DMetal (Apple)") {
                Text("If an engine lacks D3DMetal, download the Game Porting Toolkit from developer.apple.com, open the disk image and pick its redist/lib folder. Apple's licence means Sparce can't download it for you.")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("Into engine", selection: $d3dTargetID) {
                    ForEach(library.engines) { Text($0.name).tag($0.id) }
                }
                Button("Import redist/lib…") {
                    guard let engine = library.engine(id: d3dTargetID),
                          let folder = FilePicker.folder(prompt: "Import") else { return }
                    library.perform("Importing D3DMetal") {
                        try await Components.importD3DMetal(redistLib: folder, into: engine, library: library)
                        library.refreshEngines()
                    }
                }
                .disabled(library.engine(id: d3dTargetID) == nil || library.busy != nil)
            }

            Section("Translation layers") {
                LabeledContent {
                    Button(Components.dxvkInstalled ? "Reinstall" : "Download") {
                        library.perform("Installing DXVK") { try await Components.installDXVK(library: library) }
                    }
                    .disabled(library.busy != nil)
                } label: {
                    Text("DXVK for macOS")
                    Text(Components.dxvkInstalled ? "Installed" : "DX9–11 through MoltenVK")
                }

                LabeledContent {
                    Button(Components.dxmtInstalled ? "Replace…" : "Import…") {
                        guard let folder = FilePicker.folder(prompt: "Import") else { return }
                        do { try Components.importDXMT(folder: folder) ; library.append("DXMT imported.") }
                        catch { library.errorMessage = error.localizedDescription }
                    }
                } label: {
                    Text("DXMT")
                    Text(Components.dxmtInstalled ? "Installed" : "No releases yet: download a build from github.com/3Shain/dxmt (Actions), unzip, then import.")
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Components")
        .onAppear {
            library.refreshEngines()
            if library.engine(id: d3dTargetID) == nil { d3dTargetID = library.engines.first?.id ?? "" }
        }
    }
}

@MainActor
struct LogView: View {
    @EnvironmentObject var library: Library

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(library.log.enumerated()), id: \.offset) { i, line in
                        Text(line)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .id(i)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            }
            .onChange(of: library.log.count) { _, count in
                proxy.scrollTo(count - 1, anchor: .bottom)
            }
        }
        .navigationTitle("Activity")
        .toolbar {
            Button("Open Logs Folder") { NSWorkspace.shared.open(Paths.logs) }
            Button("Clear") { library.log.removeAll() }
        }
    }
}
