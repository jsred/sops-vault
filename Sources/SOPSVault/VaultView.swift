import SwiftUI
import UniformTypeIdentifiers
import VaultCore

private let vaultAccent = Color(red: 0.21, green: 0.62, blue: 0.53)

struct VaultView: View {
    @ObservedObject var model: VaultModel
    @ViewState<Bool> private var dropTarget = false
    private var saveTitle: LocalizedStringKey { model.pending.isEmpty ? "Save Changes" : "Save Changes (\(model.pending.count))" }
    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 230, ideal: 275, max: 360)
        } detail: {
            ZStack {
                Color(nsColor: .windowBackgroundColor)
                if model.locked {
                    EmptyVault(symbol: "lock.fill", title: "Your vault is locked", subtitle: model.preferences.useAuthentication
                        ? "Use Touch ID or your macOS password to continue."
                        : "Values were removed from view. Unlock to continue.") {
                            Button(action: model.unlock) {
                                Label(model.authenticating ? LocalizedStringKey("Authenticating…") : "Unlock", systemImage: "touchid")
                            }.buttonStyle(.borderedProminent).disabled(model.authenticating)
                        }
                } else if let file = model.selectedFile {
                    FileDetail(model: model, file: file)
                } else {
                    EmptyVault(symbol: "lock.shield", title: "Your secrets, under lock", subtitle: "Add a project folder or SOPS files.\nDecrypt, search and edit without leaving your Mac.") {
                        Button { ReferencePicker.show { model.add($0) } } label: {
                            Label("Add Files or Folders", systemImage: "folder.badge.plus")
                        }.buttonStyle(.borderedProminent).controlSize(.large)
                        Text("You can also drag them into this window")
                            .font(.callout).foregroundStyle(.secondary).padding(.top, 4)
                    }
                }
            }
            .overlay(alignment: .bottom) {
                if let notice = model.notice {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "info.circle.fill").foregroundStyle(vaultAccent)
                        Text(notice).font(.callout).textSelection(.disabled)
                        Button { model.notice = nil } label: { Image(systemName: "xmark") }
                            .buttonStyle(.plain).help("Dismiss notice").accessibilityLabel("Dismiss notice")
                    }
                    .padding(12).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.quaternary))
                    .padding(.horizontal, 20).padding(.bottom, model.selectedFile == nil ? 20 : 58).frame(maxWidth: 650)
                }
            }
        }
        .tint(vaultAccent)
        .toolbar {
            ToolbarItemGroup {
                Button { ReferencePicker.show { model.add($0) } } label: { Label("Add References", systemImage: "folder.badge.plus") }
                    .help("Add files or folders (⌘O)")
                Button { model.rescan() } label: { Label("Find Files", systemImage: "arrow.triangle.2.circlepath") }
                    .disabled(model.scanning).help("Search the references for files again")
                SettingsLink { Label("Settings", systemImage: "gearshape") }.help("Settings")
                Button(action: model.lock) { Label("Lock", systemImage: "lock") }
                    .disabled(model.locked).help("Lock vault (⇧⌘L)")
            }
            ToolbarItemGroup {
                if !model.pending.isEmpty {
                    Button("Discard", action: model.discardChanges).disabled(model.busy)
                        .help("Discard this file's unsaved changes")
                }
                Button(action: { model.saveChanges() }) {
                    Label(model.saving ? LocalizedStringKey("Saving…") : saveTitle, systemImage: "arrow.up.circle.fill")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.canSave)
                .help(model.status?.isGit == true ? LocalizedStringKey("Encrypt and push the changes to origin (⌘S)") : "Encrypt and save the changes (⌘S)")
            }
        }
        .overlay {
            if dropTarget {
                RoundedRectangle(cornerRadius: 16).fill(vaultAccent.opacity(0.12))
                    .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(vaultAccent, style: StrokeStyle(lineWidth: 3, dash: [8])))
                    .padding(10).allowsHitTesting(false)
            }
        }
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: $dropTarget) { providers in
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    if let url { Task { @MainActor in model.add([url]) } }
                }
            }
            return !providers.isEmpty
        }
        // initial: a selection made before the view appears (e.g. on launch) must load too.
        .onChange(of: model.selection, initial: true) { _, _ in model.loadSelection() }
        .sheet(item: $model.editor) { draft in SecretEditor(model: model, draft: draft) }
        .alert("The action could not be completed", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK") { model.error = nil }
        } message: { Text(model.error ?? "") }
        .confirmationDialog("Another change reached origin", isPresented: Binding(
            get: { !model.conflicts.isEmpty }, set: { if !$0 { model.conflicts = [] } }), titleVisibility: .visible) {
                Button("Use My Values") { model.saveChanges(resolution: .keepMine) }
                Button("Use Origin's Values") { model.saveChanges(resolution: .keepTheirs) }
                Button("Cancel", role: .cancel) { model.conflicts = [] }
            } message: {
                Text("These keys changed in origin since you started editing: \(model.conflicts.map(\.name).joined(separator: ", ")). Your other changes are applied on top of the new version.")
            }
        .alert("Origin is unreachable", isPresented: $model.offerOfflineSave) {
            Button("Save on This Mac Only") { model.saveOffline() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your changes are still pending. You can save them encrypted on this Mac only and push them when you are back online.")
        }
    }
    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "lock.shield.fill").font(.title2).foregroundStyle(vaultAccent)
                VStack(alignment: .leading, spacing: 3) {
                    Text("SOPS Vault").font(.headline)
                    Text("PERSONAL SPACE").font(.system(size: 9, weight: .semibold, design: .rounded))
                        .tracking(1.3).foregroundStyle(.secondary)
                }
                Spacer()
                if model.scanning { ProgressView().controlSize(.small) }
            }.padding(18)
            List(selection: $model.selection) {
                if model.files.isEmpty {
                    Section("Projects") {
                        Text(model.scanning ? LocalizedStringKey("Searching for files…") : "No files yet")
                            .font(.callout).foregroundStyle(.secondary).padding(.vertical, 4)
                    }
                }
                ForEach(model.projects, id: \.path) { project in
                    Section {
                        ForEach(model.files.filter { $0.projectURL == project }) { file in
                            HStack(spacing: 9) {
                                Image(systemName: "doc.text").foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack(spacing: 5) {
                                        Text(file.url.lastPathComponent).lineLimit(1)
                                        if !(model.pendingByFile[file.id] ?? []).isEmpty {
                                            Circle().fill(.orange).frame(width: 7, height: 7)
                                                .help("Unsaved changes").accessibilityLabel("Unsaved changes")
                                        }
                                    }
                                    if file.relativePath != file.url.lastPathComponent {
                                        Text(file.relativePath).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                }
                            }.padding(.vertical, 3).tag(file.id).help(file.url.path)
                        }
                    } header: { Label(project.lastPathComponent, systemImage: "folder").help(project.path) }
                }
            }.listStyle(.sidebar)
            Divider()
            HStack(spacing: 7) {
                Image(systemName: "checkmark.shield").foregroundStyle(vaultAccent)
                Text("SOPS + age").font(.caption)
                Spacer()
                Text(model.files.count == 1 ? LocalizedStringKey("1 file") : "\(model.files.count) files").font(.caption).foregroundStyle(.secondary)
            }.padding(16)
        }
    }
}

struct EmptyVault<Actions: View>: View {
    let symbol: String
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey
    @ViewBuilder let actions: () -> Actions
    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: symbol).font(.system(size: 49, weight: .light))
                .foregroundStyle(vaultAccent)
                .frame(width: 108, height: 108)
                .background(vaultAccent.opacity(0.09), in: RoundedRectangle(cornerRadius: 29))
                .overlay(RoundedRectangle(cornerRadius: 29).strokeBorder(vaultAccent.opacity(0.14)))
                .padding(.bottom, 8)
            Text(title).font(.system(size: 27, weight: .semibold, design: .rounded))
            Text(subtitle).font(.body).foregroundStyle(.secondary).multilineTextAlignment(.center).lineSpacing(5)
            VStack(spacing: 10, content: actions).padding(.top, 9)
        }.padding(45).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct FileDetail: View {
    @ObservedObject var model: VaultModel
    let file: VaultFile
    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: "doc.text.fill").font(.title).foregroundStyle(vaultAccent)
                        .frame(width: 48, height: 52).background(vaultAccent.opacity(0.09), in: RoundedRectangle(cornerRadius: 12))
                    VStack(alignment: .leading, spacing: 6) {
                        Text(file.url.lastPathComponent).font(.title2.weight(.semibold)).textSelection(.enabled)
                        Text(file.projectName + " / " + file.relativePath).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                    }
                    Spacer()
                    Label("SOPS + age", systemImage: "lock.shield").font(.caption.weight(.medium))
                        .foregroundStyle(vaultAccent).padding(.horizontal, 10).padding(.vertical, 6)
                        .background(vaultAccent.opacity(0.1), in: Capsule())
                }
                HStack {
                    Text((model.document?.entries.count ?? 0) == 1 ? LocalizedStringKey("1 key") : "\(model.document?.entries.count ?? 0) keys").font(.callout.weight(.medium))
                    Text("·").foregroundStyle(.tertiary)
                    if model.pending.isEmpty {
                        Text("Values in memory only").font(.callout).foregroundStyle(.secondary)
                    } else {
                        Text(model.pending.count == 1 ? LocalizedStringKey("1 unsaved change") : "\(model.pending.count) unsaved changes")
                            .font(.callout.weight(.medium)).foregroundStyle(.orange)
                    }
                    Spacer()
                    Button(action: model.loadSelection) { Image(systemName: "arrow.clockwise") }
                        .help("Reload file (⌘R)").accessibilityLabel("Reload File").disabled(model.busy)
                    Button { model.editor = EditorDraft(entry: nil) } label: { Label("New Key", systemImage: "plus") }
                        .disabled(model.document == nil || model.busy)
                }
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search by key name", text: $model.search).textFieldStyle(.plain)
                        .accessibilityLabel("Search by key name")
                    if !model.search.isEmpty {
                        Button { model.search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                            .buttonStyle(.plain).accessibilityLabel("Clear search")
                    }
                }.padding(10).background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
            }.padding(26)
            Divider()
            if model.busy && model.document == nil {
                VStack(spacing: 12) { ProgressView(); Text("Decrypting with SOPS…").foregroundStyle(.secondary) }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.document == nil {
                ContentUnavailableView {
                    Label("The file could not be opened", systemImage: "key.slash")
                } description: { Text("Check SOPS and the age identity in Settings and try again.") }
                actions: {
                    SettingsLink { Text("Open Settings") }
                    Button("Try Again", action: model.loadSelection)
                }
            } else if model.rows.isEmpty {
                ContentUnavailableView(model.search.isEmpty ? LocalizedStringKey("This file has no keys") : "No keys found",
                    systemImage: model.search.isEmpty ? "key" : "magnifyingglass", description: Text(model.search.isEmpty
                        ? LocalizedStringKey("Add a key to get started.") : "Try another name. Search does not look at values."))
            } else {
                HStack {
                    Text("KEY"); Spacer(); Text("PROTECTED VALUE")
                }.font(.system(size: 10, weight: .semibold)).tracking(0.8).foregroundStyle(.secondary)
                    .padding(.horizontal, 28).padding(.vertical, 13).background(.quaternary.opacity(0.16))
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(model.rows) { row in
                            SecretRow(model: model, row: row)
                            Divider().padding(.leading, 26)
                        }
                    }
                }
            }
            Divider()
            SyncBar(model: model)
        }.navigationTitle(file.url.lastPathComponent)
    }
}

struct SecretRow: View {
    @ObservedObject var model: VaultModel
    let row: SecretRowModel
    private var entry: SecretEntry { row.entry }
    private var visible: Bool { model.revealed.contains(entry.id) }
    private var deleted: Bool { row.state == .deleted }
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "key.horizontal").font(.system(size: 15)).foregroundStyle(.secondary).frame(width: 20)
            VStack(alignment: .leading, spacing: 5) {
                Text(entry.name).font(.system(.body, design: .monospaced).weight(.medium)).lineLimit(2)
                    .strikethrough(deleted).foregroundStyle(deleted ? .secondary : .primary)
                HStack(spacing: 6) {
                    Text(entry.value.typeName).font(.caption).foregroundStyle(.secondary)
                    if let badge { Text(badge.0).font(.caption2.weight(.semibold)).foregroundStyle(badge.1)
                        .padding(.horizontal, 6).padding(.vertical, 1).background(badge.1.opacity(0.13), in: Capsule()) }
                }
            }.frame(minWidth: 130, maxWidth: .infinity, alignment: .leading)
            Group {
                if visible {
                    Text(entry.value.display).font(.system(.callout, design: .monospaced)).lineLimit(3)
                        .textSelection(.enabled).strikethrough(deleted)
                } else {
                    Text("••••••••").font(.system(size: 17, weight: .medium, design: .monospaced))
                        .tracking(2).foregroundStyle(.tertiary).accessibilityLabel("Hidden value")
                }
            }.frame(minWidth: 100, maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 8) {
                Button {
                    if visible { model.revealed.remove(entry.id) } else { model.revealed.insert(entry.id) }
                } label: { Image(systemName: visible ? "eye.slash" : "eye") }
                    .help(visible ? LocalizedStringKey("Hide value") : "Show value").accessibilityLabel(visible ? LocalizedStringKey("Hide value") : "Show value")
                Button { model.copy(entry) } label: { Image(systemName: "doc.on.doc") }
                    .help("Copy for 30 seconds").accessibilityLabel("Copy value for 30 seconds")
                // Always laid out so the value column stays aligned across rows.
                Button { model.undo(row) } label: { Image(systemName: "arrow.uturn.backward") }
                    .help("Undo this change").accessibilityLabel("Undo this change")
                    .opacity(row.state == .unchanged ? 0 : 1).disabled(row.state == .unchanged)
                    .accessibilityHidden(row.state == .unchanged)
                Menu {
                    Button("Edit…", systemImage: "pencil") { model.editor = EditorDraft(entry: entry) }.disabled(deleted)
                    Button("Delete Key", systemImage: "trash", role: .destructive) { model.stage(path: entry.path, value: nil) }
                        .disabled(deleted)
                } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.borderlessButton).fixedSize().help("Key actions").accessibilityLabel("Key actions")
            }.buttonStyle(.borderless).foregroundStyle(.secondary).disabled(model.busy)
        }.padding(.horizontal, 26).padding(.vertical, 17)
        .background(row.state == .unchanged ? Color.clear : Color.orange.opacity(0.05))
    }
    private var badge: (LocalizedStringKey, Color)? {
        switch row.state {
        case .unchanged: return nil
        case .modified: return ("Modified", .orange)
        case .added: return ("New", .green)
        case .deleted: return ("Will be deleted", .red)
        }
    }
}

/// Where the file is saved and how it relates to origin and the local copy.
struct SyncBar: View {
    @ObservedObject var model: VaultModel
    var body: some View {
        HStack(spacing: 8) {
            if model.busy { ProgressView().controlSize(.small) }
            else { Image(systemName: symbol).foregroundStyle(tint) }
            Text(text).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            Spacer()
            if let status = model.status {
                if let url = status.pullRequest?.url { Link("View PR", destination: url).font(.caption) }
                if !model.localChanges.isEmpty && status.localCopy == .modified {
                    Button("Bring In Local Changes", action: model.incorporateLocalChanges).font(.caption).disabled(model.busy)
                }
                if status.isGit {
                    Button("Update Local Copy", action: model.pullLocalCopy)
                        .font(.caption)
                        .disabled(model.busy || model.unsavedCount > 0)

                    Menu {
                        Toggle("Always open a PR in this repository", isOn: Binding(
                            get: { model.status?.alwaysPullRequest ?? false }, set: { model.setAlwaysPullRequest($0) }))
                    } label: { Image(systemName: "arrow.triangle.branch") }
                        .menuStyle(.borderlessButton).fixedSize().help("How changes are pushed")
                }
            }
        }.padding(.horizontal, 24).padding(.vertical, 12)
    }
    private var text: String {
        if model.saving { return model.status?.isGit == true ? String(localized: "Encrypting, verifying and pushing to origin…") : String(localized: "Encrypting and verifying…") }
        if model.busy { return String(localized: "Decrypting with SOPS…") }
        guard let status = model.status else { return String(localized: "Changes are saved encrypted with SOPS.") }
        switch status.storage {
        case .local(let reason):
            return String(localized: "On this Mac only (\(reason)). “Save Changes” writes the encrypted file.")
        case .git(let branch):
            var parts: [String] = []
            if status.pullRequest != nil { parts.append(String(localized: "Showing the open PR; changes are added to it.")) }
            else { parts.append(status.alwaysPullRequest ? String(localized: "Saved through a PR to origin/\(branch).") : String(localized: "Synced with origin/\(branch).")) }
            if status.fetchFailed { parts.append(String(localized: "Offline: this is the last known version.")) }
            switch status.localCopy {
            case .current: break
            case .behind: parts.append(String(localized: "Your local copy is out of date (git pull)."))
            case .modified: parts.append(String(localized: "Your local copy has changes that are not in origin."))
            case .savedOffline: parts.append(String(localized: "There are changes saved offline to push."))
            case .newFile: parts.append(String(localized: "The file is not in origin yet: “Save Changes” uploads it."))
            }
            return parts.joined(separator: " ")
        }
    }
    private var symbol: String {
        guard let status = model.status else { return "lock.shield" }
        if !status.isGit { return "internaldrive" }
        if status.fetchFailed { return "wifi.slash" }
        if status.pullRequest != nil { return "arrow.triangle.pull" }
        return status.localCopy == .current || status.localCopy == .behind ? "checkmark.icloud" : "exclamationmark.icloud"
    }
    private var tint: Color {
        guard let status = model.status, status.isGit else { return .secondary }
        return status.fetchFailed || status.localCopy == .modified || status.localCopy == .savedOffline ? .orange : vaultAccent
    }
}
