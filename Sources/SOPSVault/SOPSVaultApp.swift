import SwiftUI
import AppKit

@main struct SOPSVaultApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var preferences: Preferences
    @StateObject private var model: VaultModel
    init() {
        let preferences = Preferences()
        _preferences = StateObject(wrappedValue: preferences)
        _model = StateObject(wrappedValue: VaultModel(preferences: preferences))
    }
    var body: some Scene {
        Window("SOPS Vault", id: "vault") {
            VaultView(model: model)
                .environmentObject(preferences)
                .frame(minWidth: 900, minHeight: 590)
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in model.shutdown() }
                .onReceive(NotificationCenter.default.publisher(for: .vaultOpenFiles)) { event in
                    if let urls = event.object as? [URL] { model.add(urls) }
                }
                .onChange(of: preferences.sopsPath) { _, _ in model.configurationChanged() }
                .onChange(of: preferences.keyPath) { _, _ in model.configurationChanged() }
                .onChange(of: preferences.useAuthentication) { _, _ in model.configurationChanged() }
        }
        .defaultSize(width: 1120, height: 730)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Agregar archivos o carpetas…", action: chooseReferences).keyboardShortcut("o")
            }
            CommandMenu("Bóveda") {
                Button("Bloquear bóveda", action: model.lock).keyboardShortcut("l", modifiers: [.command, .shift])
                Button("Recargar archivo", action: model.loadSelection).keyboardShortcut("r")
                    .disabled(model.locked || model.busy || model.selectedFile == nil)
            }
        }
        Settings {
            SettingsView(model: model).environmentObject(preferences)
        }
    }
    private func chooseReferences() { ReferencePicker.show { model.add($0) } }
}

extension Notification.Name { static let vaultOpenFiles = Notification.Name("vaultOpenFiles") }

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        // Never let AppKit serialize view state containing in-memory secrets.
        UserDefaults.standard.set(false, forKey: "NSQuitAlwaysKeepsWindows")
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { false }
    func application(_ application: NSApplication, open urls: [URL]) {
        NotificationCenter.default.post(name: .vaultOpenFiles, object: urls)
    }
}

enum ReferencePicker {
    @MainActor static func show(completion: @escaping ([URL]) -> Void) {
        let panel = NSOpenPanel()
        panel.title = "Agregar referencias a SOPS Vault"
        panel.prompt = "Agregar"
        panel.message = "Elegí un repositorio, una carpeta o archivos cifrados. Los archivos permanecen en su ubicación."
        panel.canChooseDirectories = true; panel.canChooseFiles = true; panel.allowsMultipleSelection = true
        panel.showsHiddenFiles = true
        panel.begin { response in if response == .OK { completion(panel.urls) } }
    }
}
