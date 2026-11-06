import SwiftUI

struct TextToolView: View {
    let draft: TextToolDraft
    let onUse: (String) -> Void
    let onCancel: () -> Void
    @State private var values: [String: String] = [:]
    @State private var output: String?
    @State private var error: String?
    @State private var running = false
    @State private var task: Task<Void, Never>?
    private var template: TextTemplate { TextTemplate(text: draft.text) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(draft.script == nil ? "Fill Template Variables" : "Transform with Script").font(.headline)
            if let script = draft.script {
                Text(script.lastPathComponent).font(.subheadline).help(script.path)
                Text("Runs this local shell script with your normal file and network access. Text is sent to stdin; stdout becomes the result. Nothing runs automatically.").font(.caption).foregroundStyle(.secondary)
                Button(running ? "Running…" : "Run Script") {
                    running = true; error = nil; output = nil
                    task = Task { @MainActor in
                        defer { running = false }
                        do { output = try await TextScriptRunner().run(script: script, input: draft.text) }
                        catch is CancellationError { }
                        catch { self.error = error.localizedDescription }
                    }
                }.disabled(running)
            } else {
                ScrollView {
                    ForEach(template.variables, id: \.self) { name in
                        TextField(name, text: Binding(get: { values[name] ?? "" }, set: { values[name] = $0 })).textFieldStyle(.roundedBorder)
                    }
                }.frame(maxHeight: 150)
            }
            Text("Preview").font(.caption.bold())
            ScrollView { Text(preview).font(.system(size: 12, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                .frame(height: 140).padding(8).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 6))
            if let error { Text(error).font(.caption).foregroundColor(.red) }
            HStack {
                Button("Cancel") { task?.cancel(); onCancel() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(draft.paste ? "Paste Result" : "Copy Result") {
                    do {
                        let text = try draft.script == nil ? template.expand(values: values) : output ?? ""
                        onUse(text)
                    } catch { self.error = error.localizedDescription }
                }.disabled(running || draft.script != nil && output == nil || draft.script == nil && template.variables.contains { values[$0] == nil })
            }
        }.padding(20).frame(width: 480).background(Color(nsColor: .windowBackgroundColor))
            .interactiveDismissDisabled().onDisappear { task?.cancel() }
    }
    private var preview: String { draft.script == nil ? ((try? template.expand(values: values)) ?? draft.text) : (output ?? draft.text) }
}
