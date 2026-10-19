import SwiftUI
import AppKit
import WebKit

@MainActor
struct StoresView: View {
    @EnvironmentObject var library: Library
    @State private var loginStore: StoreKind?

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Text("Stores").font(.largeTitle.weight(.bold))
                    Text("Sign in to bring the games you own into Sparce. Sparce uses Legendary (Epic) and gogdl (GOG), the open-source tools behind the Heroic launcher. Your sign-in stays on this Mac.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: 640, alignment: .leading)

                    HStack(alignment: .top, spacing: 18) {
                        storeCard(.epic, signedIn: library.epicSignedIn,
                                  blurb: "Your Epic library, including every weekly free game you've claimed.")
                        storeCard(.gog, signedIn: library.gogSignedIn,
                                  blurb: "DRM-free games. Many have Mac versions, which Sparce installs natively.")
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Toggle("Install Mac versions when a game has one", isOn: $library.preferMacVersions)
                            .toggleStyle(.switch)
                        LabeledContent("Games are installed in") {
                            Button(Paths.games.path) { NSWorkspace.shared.open(Paths.games) }
                                .buttonStyle(.link)
                        }
                        if library.defaultBottle == nil {
                            Label("Create a bottle in the Bottles tab so Windows games have somewhere to run.",
                                  systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.orange)
                        }
                    }
                    .padding(18)
                    .background(Theme.card, in: RoundedRectangle(cornerRadius: 14))
                }
                .padding(28)
            }
        }
        .navigationTitle("Stores")
        .preferredColorScheme(.dark)
        .sheet(item: $loginStore) { store in
            LoginSheet(store: store)
        }
    }

    private func storeCard(_ store: StoreKind, signedIn: Bool, blurb: String) -> some View {
        let count = library.games.filter { $0.store == store }.count
        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(store == .epic ? "EPIC" : "GOG")
                    .font(.system(size: 22, weight: .black, design: .rounded))
                    .frame(width: 64, height: 64)
                    .background(store == .epic ? Color.black : Color(red: 0.45, green: 0.15, blue: 0.6),
                                in: RoundedRectangle(cornerRadius: 14))
                    .foregroundStyle(.white)
                VStack(alignment: .leading, spacing: 4) {
                    Text(store.title).font(.title3.weight(.bold))
                    if signedIn {
                        Label("Connected · \(count) games", systemImage: "checkmark.circle.fill")
                            .font(.callout).foregroundStyle(.green)
                    } else {
                        Text("Not connected").font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
            Text(blurb).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                if signedIn {
                    Button {
                        library.perform("Syncing \(store.title)") { try await Stores.sync(library: library) }
                    } label: { Label("Sync library", systemImage: "arrow.clockwise") }
                    .buttonStyle(.borderedProminent).tint(Theme.accent)
                    .disabled(library.busy != nil)
                    Button("Sign out") { signOut(store) }
                } else {
                    Button { loginStore = store } label: { Label("Sign in", systemImage: "person.crop.circle") }
                        .buttonStyle(.borderedProminent).tint(Theme.accent)
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 16))
    }

    private func signOut(_ store: StoreKind) {
        library.perform("Signing out of \(store.title)") {
            if store == .epic {
                try await Stores.epicLogout(library: library)
                library.epicSignedIn = Stores.epicSignedIn
            } else {
                Stores.gogLogout()
                library.gogSignedIn = false
            }
        }
    }
}

// MARK: - Login

@MainActor
struct LoginSheet: View {
    @EnvironmentObject var library: Library
    @Environment(\.dismiss) private var dismiss
    let store: StoreKind
    @State private var manualCode = ""
    @State private var working = false

    private var startURL: URL { store == .epic ? Stores.epicLoginURL : Stores.gogLoginURL }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Sign in to \(store.title)").font(.headline)
                Spacer()
                if working { ProgressView().controlSize(.small) }
                Button("Cancel") { dismiss() }
            }
            .padding(12)

            LoginWebView(url: startURL, store: store) { code in finish(code) }

            HStack {
                Text(store == .epic
                     ? "Trouble? Open the page in your browser, sign in, and paste the authorizationCode here:"
                     : "Trouble? Open the page in your browser, sign in, and paste the code from the final URL here:")
                    .font(.caption).foregroundStyle(.secondary)
                TextField("Code", text: $manualCode).frame(width: 220)
                Button("Use code") { finish(manualCode.trimmingCharacters(in: .whitespacesAndNewlines)) }
                    .disabled(manualCode.isEmpty || working)
                Button("Open in browser") { NSWorkspace.shared.open(startURL) }
            }
            .padding(12)
        }
        .frame(width: 760, height: 720)
    }

    private func finish(_ code: String) {
        guard !working, !code.isEmpty else { return }
        working = true
        Task {
            do {
                if store == .epic {
                    try await Stores.epicLogin(code: code, library: library)
                } else {
                    try await Stores.gogLogin(code: code, library: library)
                }
                library.epicSignedIn = Stores.epicSignedIn
                library.gogSignedIn = Stores.gogSignedIn
                dismiss()
                library.perform("Syncing \(store.title)") { try await Stores.sync(library: library) }
            } catch {
                working = false
                library.errorMessage = error.localizedDescription
            }
        }
    }
}

/// Embedded browser that spots the login code automatically.
struct LoginWebView: NSViewRepresentable {
    let url: URL
    let store: StoreKind
    let onCode: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(store: store, onCode: onCode) }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: config)
        view.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
        view.navigationDelegate = context.coordinator
        view.load(URLRequest(url: url))
        return view
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        let store: StoreKind
        let onCode: (String) -> Void
        private var done = false

        init(store: StoreKind, onCode: @escaping (String) -> Void) {
            self.store = store
            self.onCode = onCode
        }

        private func deliver(_ code: String) {
            guard !done else { return }
            done = true
            DispatchQueue.main.async { self.onCode(code) }
        }

        // GOG redirects to embed.gog.com/on_login_success?code=...
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if store == .gog, let url = navigationAction.request.url,
               url.host == "embed.gog.com", url.path.hasPrefix("/on_login_success"),
               let code = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "code" })?.value {
                deliver(code)
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }

        // Epic ends on a JSON page containing "authorizationCode".
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard store == .epic else { return }
            webView.evaluateJavaScript("document.body ? document.body.innerText : ''") { [weak self] result, _ in
                guard let text = result as? String,
                      let range = text.range(of: #""authorizationCode"\s*:\s*"([^"]+)""#, options: .regularExpression)
                else { return }
                let match = String(text[range])
                let parts = match.split(separator: "\"")
                if parts.count >= 3 { self?.deliver(String(parts[parts.count - 1])) }
            }
        }
    }
}
