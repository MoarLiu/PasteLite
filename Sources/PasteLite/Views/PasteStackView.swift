import SwiftUI

struct PasteStackView: View {
    @ObservedObject var appState: AppState
    let onNext: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Paste Stack").font(.headline)
            Text(appState.stackTargetName.map { "Target: \($0)" } ?? "The next paste uses the app from which you opened this panel.")
                .font(.caption).foregroundStyle(.secondary)
            if appState.stack.isEmpty { Text("Select items or use Actions → Add to Paste Stack.").font(.caption) }
            ScrollView {
                VStack(spacing: 6) {
                    ForEach(Array(appState.stack.enumerated()), id: \.offset) { index, item in
                        HStack {
                            Text("\(index + 1). \(item.title)").lineLimit(1).help(item.title)
                            Spacer()
                            Button { appState.stack.swapAt(index, index - 1) } label: { Image(systemName: "arrow.up") }
                                .disabled(index == 0 || appState.stackBusy).accessibilityLabel("Move up")
                            Button { appState.stack.swapAt(index, index + 1) } label: { Image(systemName: "arrow.down") }
                                .disabled(index + 1 >= appState.stack.count || appState.stackBusy).accessibilityLabel("Move down")
                            Button { appState.stack.remove(at: index) } label: { Image(systemName: "xmark") }
                                .disabled(appState.stackBusy).accessibilityLabel("Remove from stack")
                        }
                    }
                }
            }.frame(maxHeight: 210)
            HStack {
                Button("Clear") { appState.stack = []; appState.resetStackTarget() }.disabled(appState.stackBusy)
                Button("Use Current Target") { appState.resetStackTarget() }.disabled(appState.stackBusy)
                Spacer()
                if appState.stackBusy { Button("Cancel", action: onCancel) }
                else { Button("Paste Next", action: onNext).disabled(appState.stack.isEmpty) }
            }
            Text("Items leave the queue only after a successful action. Failures keep the current item.").font(.caption2).foregroundStyle(.secondary)
        }.padding(16).frame(width: 420).background(Color(nsColor: .windowBackgroundColor))
    }
}
