import SwiftUI
import AppKit
import UniformTypeIdentifiers

@main
struct MdChatApp: App {
    @StateObject private var state = AppState.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(state)
                .frame(minWidth: 720, minHeight: 460)
        }
        .windowToolbarStyle(.unified(showsTitle: true))
        .commands { AppCommands(state: state) }
    }
}

struct AppCommands: Commands {
    @ObservedObject var state: AppState

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Open Markdown File…") { openFile() }
                .keyboardShortcut("o", modifiers: .command)
            Button("Reload From Disk") { state.reload() }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(state.fileURL == nil)
        }

        CommandGroup(after: .toolbar) {
            Picker("Appearance", selection: $state.appearance) {
                ForEach(Appearance.allCases) { option in
                    Text(option.label).tag(option)
                }
            }
            .pickerStyle(.inline)

            Button("Cycle Appearance") { state.cycleAppearance() }
                .keyboardShortcut("d", modifiers: [.command, .shift])

            Divider()
        }

        CommandMenu("Chat") {
            Button(state.chatVisible ? "Hide Chat" : "Show Chat") {
                state.toggleChat()
            }
            .keyboardShortcut("j", modifiers: .command)

            Button("Send Selection as Context") {
                PreviewBridge.shared.captureSelection()
            }
            .keyboardShortcut(.return, modifiers: .command)


            Divider()

            Button("Clear Attached Context") { state.pendingContext = nil }
                .disabled(state.pendingContext == nil)
            Button("New Conversation") { state.newConversation() }
                .keyboardShortcut("n", modifiers: [.command, .shift])

            Divider()

            Button("API Key & Model…") { state.showSettings = true }
                .keyboardShortcut(",", modifiers: .command)
        }
    }

    private func openFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if let md = UTType(filenameExtension: "md") {
            panel.allowedContentTypes = [md, .plainText]
        }
        if panel.runModal() == .OK, let url = panel.url {
            state.open(url: url)
        }
    }
}
