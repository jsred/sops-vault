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
                        TextField("Binario SOPS", text: $preferences.sopsPath, prompt: Text("Detección automática"))
                        Button("Elegir…") { chooseFile { preferences.sopsPath = $0.path } }
                    }
                    Text("Busca en /opt/homebrew/bin, /usr/local/bin y PATH. Requiere SOPS 3.11 o posterior para editar.")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        TextField("Identidad age", text: $preferences.keyPath)
                        Button("Elegir…") { chooseFile { preferences.keyPath = $0.path } }
                    }
                    Text("SOPS_AGE_KEY_FILE · Predeterminado: ~/.config/sops/age/keys.txt")
                        .font(.caption).foregroundStyle(.secondary)
                } header: { Text("Herramientas locales") }
                Section {
                    Toggle("Pedir Touch ID o contraseña de macOS", isOn: $preferences.useAuthentication)
                    Text("Bloquea al abrir, al suspender la Mac y tras 5 minutos sin interacción. Los valores se descartan al bloquear.")
                        .font(.caption).foregroundStyle(.secondary)
                } header: { Text("Bloqueo de la bóveda") }
                Section {
                    Label("El portapapeles se limpia a los 30 segundos o al bloquear.", systemImage: "doc.on.clipboard")
                    Label("Las referencias guardan permisos, nunca valores descifrados.", systemImage: "bookmark")
                    Text("Cambiar estos ajustes bloquea la bóveda. El bloqueo protege esta interfaz; la identidad age sigue siendo un archivo de tu usuario de macOS.")
                        .font(.caption).foregroundStyle(.secondary)
                } header: { Text("Privacidad") }
                Section {
                    Label("En repositorios git con origin, «Guardar cambios» sube solo ese archivo cifrado a la rama principal de origin.", systemImage: "arrow.up.circle")
                    Label("Tu checkout local no se modifica: actualizalo con git pull. Si la rama está protegida, se abre un PR (con gh si está instalado).", systemImage: "arrow.triangle.branch")
                    Text("Los archivos fuera de git, sin origin o ignorados por git se guardan solo en esta Mac.")
                        .font(.caption).foregroundStyle(.secondary)
                } header: { Text("Sincronización") }
            }.formStyle(.grouped).tabItem { Label("General", systemImage: "gearshape") }.tag(0)

            VStack(alignment: .leading, spacing: 16) {
                Text("Referencias").font(.title2.weight(.semibold))
                Text("Quitar una referencia no elimina los archivos originales.").font(.callout).foregroundStyle(.secondary)
                List {
                    ForEach(model.roots, id: \.path) { url in
                        HStack {
                            Image(systemName: "bookmark").foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(url.lastPathComponent).fontWeight(.medium)
                                Text(url.path).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }
                            Spacer()
                            Button("Quitar", role: .destructive) { model.remove(url) }
                        }.padding(.vertical, 5)
                    }
                }.overlay {
                    if model.roots.isEmpty { ContentUnavailableView("Sin referencias", systemImage: "bookmark", description: Text("Agregá una carpeta o un archivo para empezar.")) }
                }
                Button { ReferencePicker.show { model.add($0) } } label: { Label("Agregar referencia…", systemImage: "plus") }
            }.padding(24).tabItem { Label("Referencias", systemImage: "folder") }.tag(1)
        }.frame(width: 650, height: 640)
    }
    private func chooseFile(completion: @escaping (URL) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false; panel.canChooseFiles = true
        panel.showsHiddenFiles = true; panel.prompt = "Elegir"
        panel.begin { response in if response == .OK, let url = panel.url { completion(url) } }
    }
}
