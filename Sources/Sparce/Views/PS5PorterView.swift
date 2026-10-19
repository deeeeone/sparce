import SwiftUI
import AppKit

@MainActor
struct PS5PorterView: View {
    @EnvironmentObject var library: Library
    @State private var title = ""
    @State private var source: URL?
    @State private var target: PS5Target = .macNative
    @State private var bottleID: UUID?

    var body: some View {
        Form {
            Section {
                Text("Converts a PS5 title you dumped from your own console into a game that runs on this Mac, using AnyPS5's relinker. Sparce doesn't decrypt anything: eboot.bin must already be a decrypted ELF (or a decrypted SELF, which AnyPS5 can unwrap).")
                    .font(.callout).foregroundStyle(.secondary)
            }

            Section("AnyPS5") {
                PathRow(label: "relinker", path: $library.ps5.relinkerPath, folder: false)
                HStack {
                    Button("Build relinker from source") { buildRelinker() }
                        .disabled(library.busy != nil)
                    Text("Needs Xcode tools + `brew install cmake ninja`.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                PathRow(label: "macOS runtime libs", path: $library.ps5.macLibsDir, folder: true)
                PathRow(label: "Windows runtime libs", path: $library.ps5.windowsLibsDir, folder: true)
                PathRow(label: "AnyPS5 source (optional)", path: $library.ps5.sourceCheckout, folder: true)
                PathRow(label: "MoltenVK ICD (macOS target)", path: $library.ps5.vulkanICD, folder: false)
                if library.ps5.vulkanICD.isEmpty {
                    Button("Detect Vulkan SDK") {
                        if let icd = PS5Porter.detectVulkanICD() { library.ps5.vulkanICD = icd }
                        else { library.errorMessage = "No Vulkan SDK found. Install the LunarG Vulkan SDK for macOS (it's universal, so it works under Rosetta)." }
                    }
                }
            }

            Section("Port a title") {
                TextField("Title name", text: $title)
                HStack {
                    Text(source?.path ?? "No folder chosen").lineLimit(1).truncationMode(.middle)
                        .foregroundStyle(source == nil ? .secondary : .primary)
                    Spacer()
                    Button("Choose game folder…") {
                        if let url = FilePicker.folder() {
                            source = url
                            if title.isEmpty { title = url.lastPathComponent }
                        }
                    }
                }
                Picker("Target", selection: $target) {
                    ForEach(PS5Target.allCases) { Text($0.title).tag($0) }
                }
                Text(target == .macNative
                     ? "Runs as a real Mac app under Rosetta with Vulkan through MoltenVK. Needs AnyPS5 runtime libs built for macOS."
                     : "Fallback: builds the Windows version and runs it in a Wine bottle. Uses the Windows libs from AnyPS5 releases.")
                    .font(.caption).foregroundStyle(.secondary)
                if target == .windowsViaWine {
                    Picker("Bottle", selection: $bottleID) {
                        Text("Default").tag(UUID?.none)
                        ForEach(library.bottles) { Text($0.name).tag(Optional($0.id)) }
                    }
                }
                Button("Convert") { convert() }
                    .buttonStyle(.borderedProminent)
                    .disabled(source == nil || title.isEmpty || library.busy != nil)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("PS5 Porter")
    }

    private func convert() {
        guard let source else { return }
        let job = PS5Job(title: title, source: source, target: target,
                         bottleID: bottleID ?? library.defaultBottle?.id)
        let settings = library.ps5
        library.perform("Porting \(title)") {
            let game = try await PS5Porter.port(job, settings: settings, library: library)
            library.games.removeAll { $0.executable == game.executable }
            library.games.append(game)
        }
    }

    private func buildRelinker() {
        library.perform("Building AnyPS5 relinker") {
            let binary = try await PS5Porter.buildRelinker(library: library)
            library.ps5.relinkerPath = binary.path
            if library.ps5.sourceCheckout.isEmpty { library.ps5.sourceCheckout = PS5Porter.checkout.path }
        }
    }
}

@MainActor
struct PathRow: View {
    let label: String
    @Binding var path: String
    let folder: Bool

    var body: some View {
        LabeledContent(label) {
            HStack {
                Text(path.isEmpty ? "Not set" : path)
                    .lineLimit(1).truncationMode(.middle)
                    .foregroundStyle(path.isEmpty ? .secondary : .primary)
                Button("Choose…") {
                    let url = folder ? FilePicker.folder() : FilePicker.file()
                    if let url { path = url.path }
                }
            }
        }
    }
}
