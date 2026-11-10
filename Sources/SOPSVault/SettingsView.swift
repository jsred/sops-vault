import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: VaultModel
    @EnvironmentObject var preferences: Preferences
    @ViewState<Int> private var tab = 0
    var body: some View {
        TabView(selection: $tab) {
            Form {
                Section {
                    HStack {
                        TextField("SOPS binary", text: $preferences.sopsPath, prompt: Text("Detect automatically"))
                        Button("Choose…") { chooseFile { preferences.sopsPath = $0.path } }
                    }
                    Text("Looks in /opt/homebrew/bin, /usr/local/bin and PATH. Editing needs SOPS 3.11 or later.")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        TextField("age identity", text: $preferences.keyPath)
                        Button("Choose…") { chooseFile { preferences.keyPath = $0.path } }
                    }
                    Text("SOPS_AGE_KEY_FILE · Default: ~/.config/sops/age/keys.txt")
                        .font(.caption).foregroundStyle(.secondary)
                } header: { Text("Local Tools") }
                Section {
                    Toggle("Require Touch ID or macOS password", isOn: $preferences.useAuthentication)
                    Text("Locks on launch, when the Mac sleeps and after 5 minutes of inactivity. Values are discarded when locking.")
                        .font(.caption).foregroundStyle(.secondary)
                } header: { Text("Vault Lock") }
                Section {
                    Label("The clipboard clears after 30 seconds or when locking.", systemImage: "doc.on.clipboard")
                    Label("References store permissions, never decrypted values.", systemImage: "bookmark")
                    Text("Changing these settings locks the vault. The lock protects this interface; the age identity is still a file in your macOS user account.")
                        .font(.caption).foregroundStyle(.secondary)
                } header: { Text("Privacy") }
                Section {
                    Picker("Language", selection: $preferences.language) {
                        Text("System Default").tag("")
                        ForEach(Preferences.languages, id: \.code) { Text(verbatim: $0.name).tag($0.code) }
                    }
                    if preferences.language != preferences.launchLanguage {
                        HStack {
                            Text("SOPS Vault restarts to apply the language.").font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button("Restart Now", action: Relauncher.relaunch)
                        }
                    }
                } header: { Text("Language") }
                Section {
                    Label("In git repositories with origin, “Save Changes” pushes only that encrypted file to origin's default branch.", systemImage: "arrow.up.circle")
                    Label("Your local checkout is not modified: update it with git pull. If the branch is protected, a PR is opened (with gh if installed).", systemImage: "arrow.triangle.branch")
                    Text("Files outside git, without origin or ignored by git are saved on this Mac only.")
                        .font(.caption).foregroundStyle(.secondary)
                } header: { Text("Sync") }
            }.formStyle(.grouped).tabItem { Label("General", systemImage: "gearshape") }.tag(0)

            VStack(alignment: .leading, spacing: 16) {
                Text("References").font(.title2.weight(.semibold))
                Text("Removing a reference does not delete the original files.").font(.callout).foregroundStyle(.secondary)
                List {
                    ForEach(model.roots, id: \.path) { url in
                        HStack {
                            Image(systemName: "bookmark").foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(url.lastPathComponent).fontWeight(.medium)
                                Text(url.path).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }
                            Spacer()
                            Button("Remove", role: .destructive) { model.remove(url) }
                        }.padding(.vertical, 5)
                    }
                }.overlay {
                    if model.roots.isEmpty { ContentUnavailableView("No References", systemImage: "bookmark", description: Text("Add a folder or a file to get started.")) }
                }
                Button { ReferencePicker.show { model.add($0) } } label: { Label("Add Reference…", systemImage: "plus") }
            }.padding(24).tabItem { Label("References", systemImage: "folder") }.tag(1)
        }.frame(width: 650, height: 720)
    }
    private func chooseFile(completion: @escaping (URL) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false; panel.canChooseFiles = true
        panel.showsHiddenFiles = true; panel.prompt = String(localized: "Choose")
        panel.begin { response in if response == .OK, let url = panel.url { completion(url) } }
    }
}

enum Relauncher {
    /// Quits and opens the app again once this process has exited (gives up after ~10 s, e.g. if quitting is cancelled).
    @MainActor static func relaunch() {
        let path = Bundle.main.bundlePath
        guard path.hasSuffix(".app") else { NSApp.terminate(nil); return }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "for i in $(seq 50); do kill -0 \"$1\" 2>/dev/null || exec /usr/bin/open \"$0\"; sleep 0.2; done",
                          path, String(ProcessInfo.processInfo.processIdentifier)]
        try? task.run()
        NSApp.terminate(nil)
    }
}
