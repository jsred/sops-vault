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
            Label(draft.entry == nil ? LocalizedStringKey("New Key") : "Edit Key", systemImage: "key.horizontal")
                .font(.title2.weight(.semibold))
            Text("The change stays pending until you click “Save Changes”.")
                .font(.callout).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 7) {
                Text("Key name").font(.callout.weight(.medium))
                if let entry = draft.entry {
                    Text(entry.name).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                } else {
                    TextField("API_TOKEN", text: $name).textFieldStyle(.roundedBorder)
                    Text("It is added at the document root. Dots are part of the name.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Value").font(.callout.weight(.medium))
                    Spacer()
                    Toggle("Show", isOn: $showValue).toggleStyle(.checkbox)
                }
                if showValue {
                    TextEditor(text: $value).font(.system(.body, design: .monospaced))
                        .frame(height: 130).scrollContentBackground(.hidden)
                        .padding(6).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))
                        .accessibilityLabel("Key value")
                } else {
                    SecureField("Protected value", text: $value).textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Key value")
                    Text("Turn on Show to edit multi-line text.").font(.caption).foregroundStyle(.secondary)
                }
                if !isENV {
                    Toggle("Parse as JSON (numbers, booleans, lists or objects)", isOn: $jsonMode)
                        .toggleStyle(.checkbox).font(.callout)
                }
            }
            if let validation { Text(validation).foregroundStyle(.red).font(.callout) }
            Divider()
            HStack {
                Image(systemName: "lock.shield").foregroundStyle(.secondary)
                Text("In memory only until saved").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Apply", action: save)
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
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { validation = String(localized: "Enter a name for the key."); return }
        if draft.entry == nil && model.workingRoot?[path] != nil { validation = String(localized: "The key already exists. Edit it from the list."); return }
        let parsed: JSONValue
        if jsonMode && !isENV {
            guard let decoded = try? JSONDecoder().decode(JSONValue.self, from: Data(value.utf8)) else {
                validation = String(localized: "The value is not valid JSON. Check the syntax or turn off the JSON option."); return
            }
            parsed = decoded
        } else { parsed = .string(value) }
        model.stage(path: path, value: parsed)
    }
}
