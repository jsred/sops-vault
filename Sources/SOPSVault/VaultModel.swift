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
    @Published var status: SyncStatus?
    /// Unsaved edits per file id, in the order they were made. Plaintext stays in memory only.
    @Published var pendingByFile: [String: [SecretChange]] = [:]
    /// Unpushed edits found in the working copy, offered for incorporation.
    @Published var localChanges: [SecretChange] = []
    @Published var conflicts: [SecretChange] = []
    @Published var offerOfflineSave = false
    @Published var saving = false
    let preferences: Preferences
    private let bookmarks = BookmarkStore()
    private let sync = SyncService()
    private var access: [URL] = []
    private var generation = UUID()
    private var scanGeneration = UUID()
    private var lastActivity = ProcessInfo.processInfo.systemUptime
    private var timer: Timer?
    private var eventMonitor: Any?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var authContext: LAContext?
    var selectedFile: VaultFile? { files.first { $0.id == selection } }
    var pending: [SecretChange] { selection.flatMap { pendingByFile[$0] } ?? [] }
    var unsavedCount: Int { pendingByFile.values.reduce(0) { $0 + $1.count } }
    /// The loaded document with the pending edits applied.
    var workingRoot: JSONValue? {
        guard let document else { return nil }
        return (try? Merge.applying(pending, to: document.root)) ?? document.root
    }
    var rows: [SecretRowModel] {
        guard let document, let workingRoot else { return [] }
        let working = VaultDocument(root: workingRoot, ciphertext: Data()).entries.map { entry -> SecretRowModel in
            let base = document.root[entry.path]
            return SecretRowModel(entry: entry, state: base == nil ? .added : (base == entry.value ? .unchanged : .modified))
        }
        let deleted = document.entries.filter { workingRoot[$0.path] == nil }.map { SecretRowModel(entry: $0, state: .deleted) }
        return (working + deleted)
            .filter { search.isEmpty || $0.entry.name.localizedCaseInsensitiveContains(search) }
            .sorted { $0.entry.name.localizedStandardCompare($1.entry.name) == .orderedAscending }
    }
    var canSave: Bool {
        !locked && !busy && document != nil && (!pending.isEmpty || status?.localCopy == .newFile)
    }
    var projects: [URL] { Array(Set(files.map(\.projectURL))).sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending } }

    init(preferences: Preferences) {
        self.preferences = preferences
        locked = preferences.useAuthentication
        let restored = bookmarks.restore()
        roots = restored.urls
        access = roots.filter { $0.startAccessingSecurityScopedResource() }
        if restored.unavailable > 0 { notice = String(localized: "Some references are unavailable. Add them again from the Finder.") }
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
        #if DEBUG
        if let path = ProcessInfo.processInfo.environment["SOPS_VAULT_DEBUG_ADD"] {
            notice = nil; add([URL(fileURLWithPath: path, isDirectory: true)])
        }
        #endif
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
        let discarded = unsavedCount
        document = nil; revealed = []; search = ""; editor = nil; status = nil
        pendingByFile = [:]; localChanges = []; conflicts = []; offerOfflineSave = false
        error = nil; busy = false; saving = false
        if discarded > 0 {
            notice = discarded == 1 ? String(localized: "1 unsaved change was discarded when the vault locked.")
                                    : String(localized: "\(discarded) unsaved changes were discarded when the vault locked.")
        }
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
            error = String(localized: "macOS authentication is not available. Set up Touch ID or a login password."); return
        }
        authenticating = true; authContext = context
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: String(localized: "Unlock your SOPS Vault secrets")) { [weak self] success, _ in
            Task { @MainActor in
                guard let self, self.authContext === context else { return }
                self.authenticating = false; self.authContext = nil
                if success { self.locked = false; self.lastActivity = ProcessInfo.processInfo.systemUptime; self.loadSelection() }
                else { self.error = String(localized: "The vault was not unlocked. You can try again.") }
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
            self.error = String(localized: "The reference could not be saved. Choose it again in the file picker.")
        }
    }
    func remove(_ url: URL) {
        let remaining = roots.filter { $0 != url }
        do {
            try bookmarks.save(remaining)
            generation = UUID(); document = nil; revealed = []; editor = nil; status = nil
            roots = remaining
            access.filter { $0 == url }.forEach { $0.stopAccessingSecurityScopedResource() }
            access.removeAll { $0 == url }
            rescan()
        } catch { self.error = String(localized: "The reference could not be removed.") }
    }
    func rescan() {
        let token = UUID(); scanGeneration = token; scanning = true
        let urls = roots
        Task {
            let result = await Task.detached(priority: .userInitiated) { Discovery.scan(urls) }.value
            guard scanGeneration == token else { return }
            files = result.files; scanning = false
            if !result.warnings.isEmpty { notice = result.warnings.joined(separator: " ") }
            #if DEBUG
            debugScript()
            #endif
            if let selection, !files.contains(where: { $0.id == selection }) {
                self.selection = nil; generation = UUID(); document = nil; revealed = []; status = nil
            }
            let ids = Set(files.map(\.id))
            pendingByFile = pendingByFile.filter { ids.contains($0.key) }
        }
    }
    func pullLocalCopy() {
        guard !locked, !busy, unsavedCount == 0, let file = selectedFile else { return }
        busy = true
        let token = generation
        Task {
            do {
                try await sync.pullLocalCopy(for: file.url)
                guard generation == token, !locked else { return }
                busy = false
                loadSelection()
                rescan()
            } catch {
                guard generation == token, !locked else { return }
                busy = false
                self.error = error.localizedDescription
            }
        }
    }

    func loadSelection() {
        generation = UUID(); let token = generation
        document = nil; status = nil; revealed = []; editor = nil; error = nil; search = ""
        localChanges = []; conflicts = []; offerOfflineSave = false
        busy = false; saving = false
        guard !locked, let file = selectedFile else { return }
        busy = true
        let configuration = preferences.configuration
        Task {
            do {
                let loaded = try await sync.load(file.url, configuration: configuration)
                guard generation == token, !locked else { return }
                show(loaded, for: file)
                busy = false
            } catch {
                #if DEBUG
                FileHandle.standardError.write(Data("load failed: \(error)\n".utf8))
                #endif
                guard generation == token, !locked else { return }
                self.error = safeMessage(error); busy = false
            }
        }
    }
    private func show(_ loaded: LoadedFile, for file: VaultFile) {
        document = loaded.document; status = loaded.status
        localChanges = loaded.localChanges
        if loaded.status.localCopy == .savedOffline, !loaded.localChanges.isEmpty, (pendingByFile[file.id] ?? []).isEmpty {
            pendingByFile[file.id] = loaded.localChanges; localChanges = []
            notice = String(localized: "There are changes saved offline on this Mac. Click “Save Changes” to push them.")
        }
    }

    /// Records an edit without writing anything. `value` nil deletes the key.
    func stage(path: [PathPart], value: JSONValue?) {
        guard !locked, let file = selectedFile, let document else { return }
        var list = pendingByFile[file.id] ?? []
        if let index = list.firstIndex(where: { $0.path == path }) {
            let original = list[index].original
            if original == value { list.remove(at: index) }
            else { list[index] = SecretChange(path: path, original: original, value: value) }
        } else {
            let original = document.root[path]
            guard original != value else { return }
            list.append(SecretChange(path: path, original: original, value: value))
        }
        pendingByFile[file.id] = list.isEmpty ? nil : list
        editor = nil
    }
    func undo(_ row: SecretRowModel) {
        guard let file = selectedFile else { return }
        let list = (pendingByFile[file.id] ?? []).filter { !$0.path.isPrefix(of: row.entry.path) && !row.entry.path.isPrefix(of: $0.path) }
        pendingByFile[file.id] = list.isEmpty ? nil : list
    }
    func discardChanges() {
        guard let file = selectedFile else { return }
        pendingByFile[file.id] = nil; revealed = []
    }
    func incorporateLocalChanges() {
        guard let file = selectedFile, !localChanges.isEmpty else { return }
        var list = pendingByFile[file.id] ?? []
        for change in localChanges where !list.contains(where: { $0.path == change.path }) { list.append(change) }
        pendingByFile[file.id] = list; localChanges = []
        notice = String(localized: "Your local copy's changes were added. Click “Save Changes” to push them.")
    }
    func setAlwaysPullRequest(_ enabled: Bool) {
        guard let file = selectedFile else { return }
        status?.alwaysPullRequest = enabled
        Task { await sync.setAlwaysPullRequest(for: file.url, enabled) }
    }

    func saveChanges(resolution: ConflictResolution? = nil) {
        guard canSave, let file = selectedFile, let document else { return }
        busy = true; saving = true; conflicts = []; revealed = []
        let token = generation, changes = pending, configuration = preferences.configuration
        Task {
            do {
                let outcome = try await sync.save(file.url, changes: changes, displayed: document,
                                                  resolution: resolution, configuration: configuration)
                switch outcome {
                case .saved(let loaded, let message):
                    if pendingByFile[file.id] == changes { pendingByFile[file.id] = nil }
                    guard generation == token, !locked else { return }
                    show(loaded, for: file); notice = message
                case .conflicts(let list):
                    guard generation == token, !locked else { return }
                    conflicts = list
                }
                busy = false; saving = false
            } catch SyncError.offline {
                guard generation == token, !locked else { return }
                busy = false; saving = false; offerOfflineSave = true
            } catch {
                guard generation == token, !locked else { return }
                busy = false; saving = false; self.error = safeMessage(error)
            }
        }
    }
    func saveOffline() {
        guard !locked, !busy, let file = selectedFile, let document, !pending.isEmpty else { return }
        busy = true; saving = true; offerOfflineSave = false
        let token = generation, changes = pending, configuration = preferences.configuration
        Task {
            do {
                let loaded = try await sync.saveOffline(file.url, changes: changes, displayed: document, configuration: configuration)
                if pendingByFile[file.id] == changes { pendingByFile[file.id] = nil }
                guard generation == token, !locked else { return }
                self.document = loaded.document; self.status = loaded.status
                notice = String(localized: "Saved encrypted on this Mac only. When you are back online, open the file and click “Save Changes” to push it.")
            } catch {
                guard generation == token, !locked else { return }
                self.error = safeMessage(error)
            }
            busy = false; saving = false
        }
    }
    func copy(_ entry: SecretEntry) {
        guard !locked else { return }
        Clipboard.shared.copy(entry.value.display)
        notice = String(localized: "Copied. The clipboard clears in 30 seconds.")
    }
    func configurationChanged() { lock() }
    func shutdown() {
        Clipboard.shared.clear(); lock()
        access.forEach { $0.stopAccessingSecurityScopedResource() }; access = []
        timer?.invalidate()
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        workspaceObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
    }
    #if DEBUG
    /// Debug builds only: drives the UI for screenshots without synthetic input.
    /// SOPS_VAULT_DEBUG_ADD=<folder> SOPS_VAULT_DEBUG_SELECT=<file> SOPS_VAULT_DEBUG_STAGE=KEY=value[;KEY2=] SOPS_VAULT_DEBUG_SAVE=<seconds>
    private func debugScript() {
        let env = ProcessInfo.processInfo.environment
        guard selection == nil, let path = env["SOPS_VAULT_DEBUG_SELECT"], let file = files.first(where: { $0.url.path == Discovery.canonical(URL(fileURLWithPath: path)).path }) else { return }
        selection = file.id
        Task {
            try? await Task.sleep(for: .seconds(3))
            for item in (env["SOPS_VAULT_DEBUG_STAGE"] ?? "").split(separator: ";") {
                let parts = item.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard parts.count == 2 else { continue }
                stage(path: [.key(String(parts[0]))], value: parts[1].isEmpty ? nil : .string(String(parts[1])))
            }
            if let delay = env["SOPS_VAULT_DEBUG_SAVE"].flatMap(Double.init) {
                try? await Task.sleep(for: .seconds(delay)); saveChanges()
            }
        }
    }
    #endif
    private func safeMessage(_ error: Error) -> String {
        (error as? VaultError)?.errorDescription ?? String(localized: "The file could not be accessed. Check that it is still available and that you have permission.")
    }
}

struct SecretRowModel: Identifiable {
    enum State { case unchanged, modified, added, deleted }
    let entry: SecretEntry
    let state: State
    var id: String { entry.id }
}

struct EditorDraft: Identifiable {
    let id = UUID()
    let entry: SecretEntry?
}
