import SwiftUI
import VaultCore

struct SecretEditor: View {
    @ObservedObject var model: VaultModel
    let draft: EditorDraft
    @Environment(\.dismiss) private var dismiss
    @ViewState<String> private var name = ""
    @ViewState<String> private var value = ""
    @ViewState<Bool> private var jsonMode = false
    @ViewState<Bool> private var showValue = false
    @ViewState<String?> private var validation: String?
    private var isENV: Bool { model.selectedFile?.url.pathExtension.lowercased() == "env" }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Label(draft.entry == nil ? "Nueva clave" : "Editar clave", systemImage: "key.horizontal")
                .font(.title2.weight(.semibold))
            Text("El cambio queda pendiente hasta que toques «Guardar cambios».")
                .font(.callout).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 7) {
                Text("Nombre de la clave").font(.callout.weight(.medium))
                if let entry = draft.entry {
                    Text(entry.name).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                } else {
                    TextField("API_TOKEN", text: $name).textFieldStyle(.roundedBorder)
                    Text("Se agrega en la raíz del documento. Los puntos son parte del nombre.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Valor").font(.callout.weight(.medium))
                    Spacer()
                    Toggle("Mostrar", isOn: $showValue).toggleStyle(.checkbox)
                }
                if showValue {
                    TextEditor(text: $value).font(.system(.body, design: .monospaced))
                        .frame(height: 130).scrollContentBackground(.hidden)
                        .padding(6).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))
                        .accessibilityLabel("Valor de la clave")
                } else {
                    SecureField("Valor protegido", text: $value).textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Valor de la clave")
                    Text("Activá Mostrar para editar texto con varias líneas.").font(.caption).foregroundStyle(.secondary)
                }
                if !isENV {
                    Toggle("Interpretar como JSON (números, booleanos, listas u objetos)", isOn: $jsonMode)
                        .toggleStyle(.checkbox).font(.callout)
                }
            }
            if let validation { Text(validation).foregroundStyle(.red).font(.callout) }
            Divider()
            HStack {
                Image(systemName: "lock.shield").foregroundStyle(.secondary)
                Text("Solo en memoria hasta guardar").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancelar") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Aplicar", action: save)
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(model.busy)
            }
        }.padding(28).frame(width: 550)
        .onAppear {
            if let entry = draft.entry {
                name = entry.name
                if case .string(let text) = entry.value { value = text }
                else { value = entry.value.json; jsonMode = true }
            }
        }
    }
    private func save() {
        validation = nil
        let path = draft.entry?.path ?? [.key(name)]
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { validation = "Escribí un nombre para la clave."; return }
        if draft.entry == nil && model.workingRoot?[path] != nil { validation = "La clave ya existe. Editala desde la lista."; return }
        let parsed: JSONValue
        if jsonMode && !isENV {
            guard let decoded = try? JSONDecoder().decode(JSONValue.self, from: Data(value.utf8)) else {
                validation = "El valor no es JSON válido. Revisá la sintaxis o desactivá la opción JSON."; return
            }
            parsed = decoded
        } else { parsed = .string(value) }
        model.stage(path: path, value: parsed)
    }
}
