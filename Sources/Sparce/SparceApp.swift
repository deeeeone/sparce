import SwiftUI
import AppKit
import UniformTypeIdentifiers

@main
struct SparceApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var library = Library()

    var body: some Scene {
        WindowGroup("Sparce") {
            ContentView()
                .environmentObject(library)
                .frame(minWidth: 900, minHeight: 600)
        }
        .windowStyle(.hiddenTitleBar)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when run as a bare SwiftPM executable (no .app bundle).
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

enum SidebarItem: String, CaseIterable, Identifiable {
    case library = "Library"
    case bottles = "Bottles"
    case ps5 = "PS5 Porter"
    case components = "Components"
    case log = "Activity"

    var id: String { rawValue }
    var icon: String {
        switch self {
        case .library: return "gamecontroller"
        case .bottles: return "shippingbox"
        case .ps5: return "arrow.triangle.2.circlepath"
        case .components: return "cpu"
        case .log: return "text.alignleft"
        }
    }
}

@MainActor
struct ContentView: View {
    @EnvironmentObject var library: Library
    @State private var section: SidebarItem? = .library

    var body: some View {
        NavigationSplitView {
            List(SidebarItem.allCases, selection: $section) { item in
                Label(item.rawValue, systemImage: item.icon).tag(item)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
            .safeAreaInset(edge: .bottom) {
                if let busy = library.busy {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(busy).font(.caption).lineLimit(2)
                    }
                    .padding(10)
                }
            }
        } detail: {
            switch section ?? .library {
            case .library: LibraryView()
            case .bottles: BottlesView()
            case .ps5: PS5PorterView()
            case .components: ComponentsView()
            case .log: LogView()
            }
        }
        .alert("Something went wrong", isPresented: Binding(
            get: { library.errorMessage != nil },
            set: { if !$0 { library.errorMessage = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(library.errorMessage ?? "")
        }
    }
}

enum FilePicker {
    @MainActor
    static func file(types: [String] = [], prompt: String = "Choose") -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = prompt
        if !types.isEmpty {
            panel.allowedContentTypes = types.compactMap { UTType(filenameExtension: $0) }
        }
        return panel.runModal() == .OK ? panel.url : nil
    }

    @MainActor
    static func folder(prompt: String = "Choose") -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = prompt
        return panel.runModal() == .OK ? panel.url : nil
    }
}

