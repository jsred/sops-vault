import SwiftUI
import AppKit

@main struct SOPSVaultApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var preferences: Preferences
    @StateObject private var model: VaultModel
    init() {
        let preferences = Preferences()
        _preferences = StateObject(wrappedValue: preferences)
        let model = VaultModel(preferences: preferences)
        _model = StateObject(wrappedValue: model)
        OpenRequests.shared.handler = { [weak model] urls in model?.add(urls) }
        UnsavedChanges.count = { [weak model] in model?.unsavedCount ?? 0 }
    }
    var body: some Scene {
        Window("SOPS Vault", id: "vault") {
            VaultView(model: model)
                .environmentObject(preferences)
                .frame(minWidth: 900, minHeight: 590)
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in model.shutdown() }
                .onChange(of: preferences.sopsPath) { _, _ in model.configurationChanged() }
                .onChange(of: preferences.keyPath) { _, _ in model.configurationChanged() }
                .onChange(of: preferences.useAuthentication) { _, _ in model.configurationChanged() }
        }
        .defaultSize(width: 1120, height: 730)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Add Files or Folders…", action: chooseReferences).keyboardShortcut("o")
            }
            CommandMenu("Vault") {
                Button("Lock Vault", action: model.lock).keyboardShortcut("l", modifiers: [.command, .shift])
                Button("Save Changes") { model.saveChanges() }.keyboardShortcut("s")
                    .disabled(!model.canSave)
                Button("Reload File", action: model.loadSelection).keyboardShortcut("r")
                    .disabled(model.locked || model.busy || model.selectedFile == nil)
            }
        }
        Settings {
            SettingsView(model: model).environmentObject(preferences)
        }
    }
    private func chooseReferences() { ReferencePicker.show { model.add($0) } }
}

/// Buffers Finder/`open -a` requests that arrive before the model is ready (cold launch).
@MainActor final class OpenRequests {
    static let shared = OpenRequests()
    private var pending: [URL] = []
    var handler: (([URL]) -> Void)? { didSet { flush() } }
    func receive(_ urls: [URL]) { pending += urls; flush() }
    private func flush() {
        guard let handler, !pending.isEmpty else { return }
        let urls = pending; pending = []
        handler(urls)
    }
}

@MainActor enum UnsavedChanges {
    static var count: () -> Int = { 0 }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated {
            let count = UnsavedChanges.count()
            guard count > 0 else { return .terminateNow }
            let alert = NSAlert()
            alert.messageText = count == 1 ? String(localized: "You have 1 unsaved change") : String(localized: "You have \(count) unsaved changes")
            alert.informativeText = String(localized: "If you quit now, those changes are lost. Unsaved values are never written to disk.")
            alert.addButton(withTitle: String(localized: "Cancel"))
            alert.addButton(withTitle: String(localized: "Quit Without Saving"))
            return alert.runModal() == .alertSecondButtonReturn ? .terminateNow : .terminateCancel
        }
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        // Never let AppKit serialize view state containing in-memory secrets.
        UserDefaults.standard.set(false, forKey: "NSQuitAlwaysKeepsWindows")
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { false }
    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated { OpenRequests.shared.receive(urls) }
    }
}

enum ReferencePicker {
    @MainActor static func show(completion: @escaping ([URL]) -> Void) {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Add References to SOPS Vault")
        panel.prompt = String(localized: "Add")
        panel.message = String(localized: "Choose a repository, a folder or encrypted files. Files stay where they are.")
        panel.canChooseDirectories = true; panel.canChooseFiles = true; panel.allowsMultipleSelection = true
        panel.showsHiddenFiles = true
        panel.begin { response in if response == .OK { completion(panel.urls) } }
    }
}
