import SwiftUI
import UniformTypeIdentifiers
import VaultCore

private let vaultAccent = Color(red: 0.21, green: 0.62, blue: 0.53)

struct VaultView: View {
    @ObservedObject var model: VaultModel
    @ViewState<Bool> private var dropTarget = false
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
                    .padding(20).frame(maxWidth: 650)
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
        .confirmationDialog("¿Eliminar esta clave del archivo cifrado?", isPresented: Binding(
            get: { model.pendingDelete != nil }, set: { if !$0 { model.pendingDelete = nil } }), titleVisibility: .visible) {
                if let entry = model.pendingDelete {
                    Button("Eliminar clave", role: .destructive) { model.save(path: entry.path, value: nil) }
                }
                Button("Cancelar", role: .cancel) { model.pendingDelete = nil }
            } message: { Text(model.pendingDelete?.name ?? "") }
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
                                    Text(file.url.lastPathComponent).lineLimit(1)
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
                    Text("Valores solo en memoria").font(.callout).foregroundStyle(.secondary)
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
            } else if model.filteredEntries.isEmpty {
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
                        ForEach(model.filteredEntries) { entry in
                            SecretRow(model: model, entry: entry)
                            Divider().padding(.leading, 26)
                        }
                    }
                }
            }
            Divider()
            HStack(spacing: 7) {
                if model.busy { ProgressView().controlSize(.small) }
                else { Image(systemName: "externaldrive.badge.checkmark").foregroundStyle(vaultAccent) }
                Text(model.busy ? "Guardando y verificando…" : "Los cambios se guardan cifrados en el archivo original.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
            }.padding(.horizontal, 24).padding(.vertical, 13)
        }.navigationTitle(file.url.lastPathComponent)
    }
}

struct SecretRow: View {
    @ObservedObject var model: VaultModel
    let entry: SecretEntry
    private var visible: Bool { model.revealed.contains(entry.id) }
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "key.horizontal").font(.system(size: 15)).foregroundStyle(.secondary).frame(width: 20)
            VStack(alignment: .leading, spacing: 5) {
                Text(entry.name).font(.system(.body, design: .monospaced).weight(.medium)).lineLimit(2)
                Text(entry.value.typeName).font(.caption).foregroundStyle(.secondary)
            }.frame(minWidth: 130, maxWidth: .infinity, alignment: .leading)
            Group {
                if visible {
                    Text(entry.value.display).font(.system(.callout, design: .monospaced)).lineLimit(3)
                        .textSelection(.enabled)
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
                Menu {
                    Button("Editar…", systemImage: "pencil") { model.editor = EditorDraft(entry: entry) }
                    Button("Eliminar clave…", systemImage: "trash", role: .destructive) { model.pendingDelete = entry }
                } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.borderlessButton).fixedSize().help("Acciones de la clave").accessibilityLabel("Acciones de la clave")
            }.buttonStyle(.borderless).foregroundStyle(.secondary).disabled(model.busy)
        }.padding(.horizontal, 26).padding(.vertical, 17)
    }
}
