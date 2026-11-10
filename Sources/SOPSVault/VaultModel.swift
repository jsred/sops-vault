import SwiftUI
@preconcurrency import LocalAuthentication
import VaultCore

@MainActor final class VaultModel: ObservableObject {
    @Published var files: [VaultFile] = []
    @Published var roots: [URL] = []
    @Published var selection: String?
    @Published var document: VaultDocument?
    @Published var revealed: Set<String> = []
    @Published var search = ""
    @Published var busy = false
    @Published var scanning = false
    @Published var locked = false
    @Published var authenticating = false
    @Published var error: String?
    @Published var notice: String?
    @Published var editor: EditorDraft?
    @Published var pendingDelete: SecretEntry?
    let preferences: Preferences
    private let bookmarks = BookmarkStore()
    private let service = SOPSService()
    private var access: [URL] = []
    private var generation = UUID()
    private var scanGeneration = UUID()
    private var lastActivity = ProcessInfo.processInfo.systemUptime
    private var timer: Timer?
    private var eventMonitor: Any?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var authContext: LAContext?
    var selectedFile: VaultFile? { files.first { $0.id == selection } }
    var filteredEntries: [SecretEntry] {
        (document?.entries ?? []).filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }
    }
    var projects: [URL] { Array(Set(files.map(\.projectURL))).sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending } }

    init(preferences: Preferences) {
        self.preferences = preferences
        locked = preferences.useAuthentication
        let restored = bookmarks.restore()
        roots = restored.urls
        access = roots.filter { $0.startAccessingSecurityScopedResource() }
        if restored.unavailable > 0 { notice = "Hay referencias no disponibles. Volvé a agregarlas desde el Finder." }
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .scrollWheel, .mouseMoved]) { [weak self] event in
            Task { @MainActor in self?.activity() }; return event
        }
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkInactivity() }
        }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            workspaceObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.lock() }
            })
        }
        rescan()
    }

    func activity() {
        // Test the previous deadline before resetting it, including the first event after a pause.
        checkInactivity()
        lastActivity = ProcessInfo.processInfo.systemUptime
    }
    func checkInactivity() {
        if preferences.useAuthentication && !locked && ProcessInfo.processInfo.systemUptime - lastActivity >= 300 { lock() }
    }
    func lock() {
        generation = UUID()
        document = nil; revealed = []; search = ""; editor = nil; pendingDelete = nil
        error = nil; busy = false
        Clipboard.shared.clear()
        locked = true
        authContext?.invalidate(); authContext = nil; authenticating = false
    }
    func unlock() {
        guard !authenticating else { return }
        if !preferences.useAuthentication {
            locked = false; lastActivity = ProcessInfo.processInfo.systemUptime; loadSelection(); return
        }
        let context = LAContext()
        var failure: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &failure) else {
            error = "No se pudo usar la autenticación de macOS. Configurá Touch ID o la contraseña de inicio de sesión."; return
        }
        authenticating = true; authContext = context
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Desbloquear los secretos de SOPS Vault") { [weak self] success, _ in
            Task { @MainActor in
                guard let self, self.authContext === context else { return }
                self.authenticating = false; self.authContext = nil
                if success { self.locked = false; self.lastActivity = ProcessInfo.processInfo.systemUptime; self.loadSelection() }
                else { self.error = "No se desbloqueó la bóveda. Podés volver a intentar." }
            }
        }
    }
    func add(_ urls: [URL]) {
        let new = urls.map(\.standardizedFileURL).filter { !roots.contains($0) }
        guard !new.isEmpty else { return }
        let newlyAccessed = new.filter { $0.startAccessingSecurityScopedResource() }
        do {
            try bookmarks.save(roots + new)
            access += newlyAccessed; roots += new; rescan()
        } catch {
            newlyAccessed.forEach { $0.stopAccessingSecurityScopedResource() }
            self.error = "No se pudo guardar la referencia. Volvé a elegirla en el selector de archivos."
        }
    }
    func remove(_ url: URL) {
        let remaining = roots.filter { $0 != url }
        do {
            try bookmarks.save(remaining)
            generation = UUID(); document = nil; revealed = []; editor = nil; pendingDelete = nil
            roots = remaining
            access.filter { $0 == url }.forEach { $0.stopAccessingSecurityScopedResource() }
            access.removeAll { $0 == url }
            rescan()
        } catch { self.error = "No se pudo quitar la referencia." }
    }
    func rescan() {
        let token = UUID(); scanGeneration = token; scanning = true
        let urls = roots
        Task {
            let result = await Task.detached(priority: .userInitiated) { Discovery.scan(urls) }.value
            guard scanGeneration == token else { return }
            files = result.files; scanning = false
            if !result.warnings.isEmpty { notice = result.warnings.joined(separator: " ") }
            if let selection, !files.contains(where: { $0.id == selection }) {
                self.selection = nil; generation = UUID(); document = nil; revealed = []
            }
        }
    }
    func loadSelection() {
        generation = UUID(); let token = generation
        document = nil; revealed = []; editor = nil; pendingDelete = nil; error = nil; search = ""
        busy = false
        guard !locked, let file = selectedFile else { return }
        busy = true
        let configuration = preferences.configuration
        Task {
            do {
                let loaded = try await service.load(url: file.url, configuration: configuration)
                guard generation == token, !locked else { return }
                document = loaded; busy = false
            } catch {
                guard generation == token, !locked else { return }
                self.error = safeMessage(error); busy = false
            }
        }
    }
    func save(path: [PathPart], value: JSONValue?) {
        guard !locked, !busy, let file = selectedFile, let document else { return }
        busy = true; revealed = []; let token = generation
        let config = preferences.configuration
        Task {
            do {
                let updated = try await service.mutate(url: file.url, expectedCiphertext: document.ciphertext,
                    path: path, value: value, configuration: config)
                guard generation == token, !locked else { return }
                self.document = updated; busy = false; editor = nil; pendingDelete = nil
                notice = "Cambio guardado y verificado con SOPS."
            } catch {
                guard generation == token, !locked else { return }
                busy = false; self.error = safeMessage(error)
            }
        }
    }
    func copy(_ entry: SecretEntry) {
        guard !locked else { return }
        Clipboard.shared.copy(entry.value.display)
        notice = "Copiado. El portapapeles se limpia en 30 segundos."
    }
    func configurationChanged() { lock() }
    func shutdown() {
        Clipboard.shared.clear(); lock()
        access.forEach { $0.stopAccessingSecurityScopedResource() }; access = []
        timer?.invalidate()
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        workspaceObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
    }
    private func safeMessage(_ error: Error) -> String {
        (error as? VaultError)?.errorDescription ?? "No se pudo acceder al archivo. Revisá que siga disponible y que tengas permisos."
    }
}

struct EditorDraft: Identifiable {
    let id = UUID()
    let entry: SecretEntry?
}
