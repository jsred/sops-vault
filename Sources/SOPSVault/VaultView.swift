import SwiftUI
import UniformTypeIdentifiers
import VaultCore

private let vaultAccent = Color(red: 0.21, green: 0.62, blue: 0.53)

struct VaultView: View {
    @ObservedObject var model: VaultModel
    @ViewState<Bool> private var dropTarget = false
    private var saveTitle: String { model.pending.isEmpty ? "Guardar cambios" : "Guardar cambios (\(model.pending.count))" }
    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 230, ideal: 275, max: 360)
        } detail: {
            ZStack {
                Color(nsColor: .windowBackgroundColor)
                if model.locked {
                    EmptyVault(symbol: "lock.fill", title: "Tu bóveda está bloqueada", subtitle: model.preferences.useAuthentication
                        ? "Usá Touch ID o tu contraseña de macOS para continuar."
                        : "Los valores se quitaron de la vista. Desbloqueá para continuar.") {
                            Button(action: model.unlock) {
                                Label(model.authenticating ? "Autenticando…" : "Desbloquear", systemImage: "touchid")
                            }.buttonStyle(.borderedProminent).disabled(model.authenticating)
                        }
                } else if let file = model.selectedFile {
                    FileDetail(model: model, file: file)
                } else {
                    EmptyVault(symbol: "lock.shield", title: "Tus secretos, bajo llave", subtitle: "Agregá una carpeta de proyecto o archivos SOPS.\nDescifrá, buscá y editá sin salir de tu Mac.") {
                        Button { ReferencePicker.show { model.add($0) } } label: {
                            Label("Agregar archivos o carpetas", systemImage: "folder.badge.plus")
                        }.buttonStyle(.borderedProminent).controlSize(.large)
                        Text("También podés arrastrarlos a esta ventana")
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
                            .buttonStyle(.plain).help("Cerrar aviso").accessibilityLabel("Cerrar aviso")
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
                Button { ReferencePicker.show { model.add($0) } } label: { Label("Agregar referencias", systemImage: "folder.badge.plus") }
                    .help("Agregar archivos o carpetas (⌘O)")
                Button { model.rescan() } label: { Label("Buscar archivos", systemImage: "arrow.triangle.2.circlepath") }
                    .disabled(model.scanning).help("Volver a buscar archivos en las referencias")
                SettingsLink { Label("Ajustes", systemImage: "gearshape") }.help("Ajustes")
                Button(action: model.lock) { Label("Bloquear", systemImage: "lock") }
                    .disabled(model.locked).help("Bloquear bóveda (⇧⌘L)")
            }
            ToolbarItemGroup {
                if !model.pending.isEmpty {
                    Button("Descartar", action: model.discardChanges).disabled(model.busy)
                        .help("Descartar los cambios sin guardar de este archivo")
                }
                Button(action: { model.saveChanges() }) {
                    Label(model.saving ? "Guardando…" : saveTitle, systemImage: "arrow.up.circle.fill")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.canSave)
                .help(model.status?.isGit == true ? "Cifrar y subir los cambios a origin (⌘S)" : "Cifrar y guardar los cambios (⌘S)")
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
        .onChange(of: model.selection) { _, _ in model.loadSelection() }
        .sheet(item: $model.editor) { draft in SecretEditor(model: model, draft: draft) }
        .alert("No se pudo completar la acción", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("Aceptar") { model.error = nil }
        } message: { Text(model.error ?? "") }
        .confirmationDialog("Otro cambio llegó a origin", isPresented: Binding(
            get: { !model.conflicts.isEmpty }, set: { if !$0 { model.conflicts = [] } }), titleVisibility: .visible) {
                Button("Usar mis valores") { model.saveChanges(resolution: .keepMine) }
                Button("Usar los de origin") { model.saveChanges(resolution: .keepTheirs) }
                Button("Cancelar", role: .cancel) { model.conflicts = [] }
            } message: {
                Text("Estas claves cambiaron en origin desde que empezaste a editar: \(model.conflicts.map(\.name).joined(separator: ", ")). El resto de tus cambios se aplica sobre la versión nueva.")
            }
        .alert("No hay conexión con origin", isPresented: $model.offerOfflineSave) {
            Button("Guardar solo en esta Mac") { model.saveOffline() }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("Tus cambios siguen pendientes. Podés guardarlos cifrados solo en esta Mac y subirlos cuando vuelva la conexión.")
        }
    }
    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "lock.shield.fill").font(.title2).foregroundStyle(vaultAccent)
                VStack(alignment: .leading, spacing: 3) {
                    Text("SOPS Vault").font(.headline)
                    Text("ESPACIO PERSONAL").font(.system(size: 9, weight: .semibold, design: .rounded))
                        .tracking(1.3).foregroundStyle(.secondary)
                }
                Spacer()
                if model.scanning { ProgressView().controlSize(.small) }
            }.padding(18)
            List(selection: $model.selection) {
                if model.files.isEmpty {
                    Section("Proyectos") {
                        Text(model.scanning ? "Buscando archivos…" : "Todavía no hay archivos")
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
                                                .help("Cambios sin guardar").accessibilityLabel("Cambios sin guardar")
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
                Text("\(model.files.count) archivos").font(.caption).foregroundStyle(.secondary)
            }.padding(16)
        }
    }
}

struct EmptyVault<Actions: View>: View {
    let symbol: String
    let title: String
    let subtitle: String
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
                    Text("\(model.document?.entries.count ?? 0) claves").font(.callout.weight(.medium))
                    Text("·").foregroundStyle(.tertiary)
                    if model.pending.isEmpty {
                        Text("Valores solo en memoria").font(.callout).foregroundStyle(.secondary)
                    } else {
                        Text(model.pending.count == 1 ? "1 cambio sin guardar" : "\(model.pending.count) cambios sin guardar")
                            .font(.callout.weight(.medium)).foregroundStyle(.orange)
                    }
                    Spacer()
                    Button(action: model.loadSelection) { Image(systemName: "arrow.clockwise") }
                        .help("Recargar archivo (⌘R)").accessibilityLabel("Recargar archivo").disabled(model.busy)
                    Button { model.editor = EditorDraft(entry: nil) } label: { Label("Nueva clave", systemImage: "plus") }
                        .disabled(model.document == nil || model.busy)
                }
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Buscar por nombre de clave", text: $model.search).textFieldStyle(.plain)
                        .accessibilityLabel("Buscar por nombre de clave")
                    if !model.search.isEmpty {
                        Button { model.search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                            .buttonStyle(.plain).accessibilityLabel("Limpiar búsqueda")
                    }
                }.padding(10).background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
            }.padding(26)
            Divider()
            if model.busy && model.document == nil {
                VStack(spacing: 12) { ProgressView(); Text("Descifrando con SOPS…").foregroundStyle(.secondary) }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.document == nil {
                ContentUnavailableView {
                    Label("No se pudo abrir el archivo", systemImage: "key.slash")
                } description: { Text("Revisá SOPS y la identidad age en Ajustes y volvé a intentar.") }
                actions: {
                    SettingsLink { Text("Abrir Ajustes") }
                    Button("Volver a intentar", action: model.loadSelection)
                }
            } else if model.rows.isEmpty {
                ContentUnavailableView(model.search.isEmpty ? "Este archivo no tiene claves" : "No se encontraron claves",
                    systemImage: model.search.isEmpty ? "key" : "magnifyingglass", description: Text(model.search.isEmpty
                        ? "Agregá una clave para empezar." : "Probá con otro nombre. La búsqueda no examina valores."))
            } else {
                HStack {
                    Text("CLAVE"); Spacer(); Text("VALOR PROTEGIDO")
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
                        .tracking(2).foregroundStyle(.tertiary).accessibilityLabel("Valor oculto")
                }
            }.frame(minWidth: 100, maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 8) {
                Button {
                    if visible { model.revealed.remove(entry.id) } else { model.revealed.insert(entry.id) }
                } label: { Image(systemName: visible ? "eye.slash" : "eye") }
                    .help(visible ? "Ocultar valor" : "Mostrar valor").accessibilityLabel(visible ? "Ocultar valor" : "Mostrar valor")
                Button { model.copy(entry) } label: { Image(systemName: "doc.on.doc") }
                    .help("Copiar por 30 segundos").accessibilityLabel("Copiar valor por 30 segundos")
                // Always laid out so the value column stays aligned across rows.
                Button { model.undo(row) } label: { Image(systemName: "arrow.uturn.backward") }
                    .help("Deshacer este cambio").accessibilityLabel("Deshacer este cambio")
                    .opacity(row.state == .unchanged ? 0 : 1).disabled(row.state == .unchanged)
                    .accessibilityHidden(row.state == .unchanged)
                Menu {
                    Button("Editar…", systemImage: "pencil") { model.editor = EditorDraft(entry: entry) }.disabled(deleted)
                    Button("Eliminar clave", systemImage: "trash", role: .destructive) { model.stage(path: entry.path, value: nil) }
                        .disabled(deleted)
                } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.borderlessButton).fixedSize().help("Acciones de la clave").accessibilityLabel("Acciones de la clave")
            }.buttonStyle(.borderless).foregroundStyle(.secondary).disabled(model.busy)
        }.padding(.horizontal, 26).padding(.vertical, 17)
        .background(row.state == .unchanged ? Color.clear : Color.orange.opacity(0.05))
    }
    private var badge: (String, Color)? {
        switch row.state {
        case .unchanged: return nil
        case .modified: return ("Modificada", .orange)
        case .added: return ("Nueva", .green)
        case .deleted: return ("Se eliminará", .red)
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
                if let url = status.pullRequest?.url { Link("Ver PR", destination: url).font(.caption) }
                if !model.localChanges.isEmpty && status.localCopy == .modified {
                    Button("Incorporar cambios locales", action: model.incorporateLocalChanges).font(.caption).disabled(model.busy)
                }
                if status.isGit {
                    Menu {
                        Toggle("Abrir siempre un PR en este repositorio", isOn: Binding(
                            get: { model.status?.alwaysPullRequest ?? false }, set: { model.setAlwaysPullRequest($0) }))
                    } label: { Image(systemName: "arrow.triangle.branch") }
                        .menuStyle(.borderlessButton).fixedSize().help("Cómo se suben los cambios")
                }
            }
        }.padding(.horizontal, 24).padding(.vertical, 12)
    }
    private var text: String {
        if model.saving { return model.status?.isGit == true ? "Cifrando, verificando y subiendo a origin…" : "Cifrando y verificando…" }
        if model.busy { return "Descifrando con SOPS…" }
        guard let status = model.status else { return "Los cambios se guardan cifrados con SOPS." }
        switch status.storage {
        case .local(let reason):
            return "Solo en esta Mac (\(reason)). «Guardar cambios» escribe el archivo cifrado."
        case .git(let branch):
            var parts: [String] = []
            if status.pullRequest != nil { parts.append("Mostrando el PR abierto; los cambios se suman a ese PR.") }
            else { parts.append(status.alwaysPullRequest ? "Se guarda con un PR hacia origin/\(branch)." : "Sincronizado con origin/\(branch).") }
            if status.fetchFailed { parts.append("Sin conexión: es la última versión conocida.") }
            switch status.localCopy {
            case .current: break
            case .behind: parts.append("Tu copia local está desactualizada (git pull).")
            case .modified: parts.append("Tu copia local tiene cambios que no están en origin.")
            case .savedOffline: parts.append("Hay cambios guardados sin conexión para subir.")
            case .newFile: parts.append("El archivo todavía no está en origin: «Guardar cambios» lo sube.")
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
