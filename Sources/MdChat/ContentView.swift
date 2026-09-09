import SwiftUI

struct ContentView: View {
    @EnvironmentObject var state: AppState
    @State private var panelWidth: CGFloat = 380

    var body: some View {
        HStack(spacing: 0) {
            PreviewView(markdown: state.markdown) { text in
                state.attach(context: text)
            }
            .frame(minWidth: 320)

            if state.chatVisible {
                Divider()
                ChatPanel()
                    .frame(width: panelWidth)
                    .transition(.move(edge: .trailing))
            }
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Text(state.fileURL?.lastPathComponent ?? "No file open")
                    .foregroundStyle(.secondary)
            }
            ToolbarItem {
                Button {
                    state.toggleChat()
                } label: {
                    Image(systemName: state.chatVisible
                          ? "sidebar.trailing"
                          : "bubble.left.and.text.bubble.right")
                }
                .help("Toggle chat (⌘J)")
            }
        }
        .sheet(isPresented: $state.showSettings) { SettingsSheet() }
        .navigationTitle("MdChat")
    }
}

struct SettingsSheet: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var key = ""
    @State private var model = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Gemini").font(.headline)

            VStack(alignment: .leading, spacing: 4) {
                Text("API key").font(.subheadline).foregroundStyle(.secondary)
                SecureField("AIza…", text: $key)
                    .textFieldStyle(.roundedBorder)
                Text("Stored in your login Keychain.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Model ID").font(.subheadline).foregroundStyle(.secondary)
                TextField("gemini-flash-latest", text: $model)
                    .textFieldStyle(.roundedBorder)
                Text("Whatever string the API expects, e.g. a specific Flash version.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") {
                    state.saveKey(key)
                    let trimmed = model.trimmingCharacters(in: .whitespaces)
                    if !trimmed.isEmpty { state.modelID = trimmed }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 400)
        .onAppear {
            key = state.apiKey
            model = state.modelID
        }
    }
}
