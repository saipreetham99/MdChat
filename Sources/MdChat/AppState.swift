import Foundation
import SwiftUI

struct ChatMessage: Identifiable, Equatable {
    enum Role: String { case user, model }
    let id = UUID()
    let role: Role
    var text: String
    var context: String? = nil
}

@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    @Published var fileURL: URL?
    @Published var markdown: String = AppState.welcome
    @Published var chatVisible = true
    @Published var pendingContext: String?
    @Published var messages: [ChatMessage] = []
    @Published var isSending = false
    @Published var errorText: String?
    @Published var showSettings = false

    @Published var modelID: String {
        didSet { UserDefaults.standard.set(modelID, forKey: "modelID") }
    }
    @Published var apiKey: String = ""

    private var watcher: FileWatcher?

    private init() {
        modelID = UserDefaults.standard.string(forKey: "modelID") ?? "gemini-flash-latest"
        apiKey = Keychain.read() ?? ""
    }

    // MARK: - Document

    func open(url: URL) {
        watcher = nil
        fileURL = url
        reload()
        watcher = FileWatcher(url: url) { [weak self] in
            self?.reload()
        }
    }

    func reload() {
        guard let url = fileURL else { return }
        do {
            markdown = try String(contentsOf: url, encoding: .utf8)
        } catch {
            errorText = "Couldn't read \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    // MARK: - Chat

    func toggleChat() {
        withAnimation(.easeOut(duration: 0.18)) { chatVisible.toggle() }
    }

    func attach(context: String) {
        let trimmed = context.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        pendingContext = trimmed
        chatVisible = true
    }

    func saveKey(_ key: String) {
        apiKey = key
        Keychain.write(key)
    }

    func send(_ prompt: String) {
        let question = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !isSending else { return }
        guard !apiKey.isEmpty else {
            errorText = "Add a Gemini API key first (⌘,)."
            showSettings = true
            return
        }

        let context = pendingContext
        messages.append(ChatMessage(role: .user, text: question, context: context))
        pendingContext = nil
        isSending = true
        errorText = nil

        let turns = messages.map { msg -> Gemini.Turn in
            var text = msg.text
            if msg.role == .user, let ctx = msg.context {
                text = "Selected from the document:\n---\n\(ctx)\n---\n\nQuestion: \(msg.text)"
            }
            return Gemini.Turn(role: msg.role.rawValue, text: text)
        }

        let key = apiKey, model = modelID
        let name = fileURL?.lastPathComponent ?? "untitled.md"

        Task {
            do {
                let reply = try await Gemini.generate(
                    apiKey: key,
                    model: model,
                    system: """
                    You answer questions about a Markdown document the user is reading (\(name)). \
                    The user attaches the exact excerpt they selected. Answer about that excerpt \
                    directly and concisely. Say so when the excerpt is not enough to answer.
                    """,
                    turns: turns
                )
                messages.append(ChatMessage(role: .model, text: reply))
            } catch {
                errorText = error.localizedDescription
            }
            isSending = false
        }
    }

    static let welcome = """
    # MdChat

    Open a file with **⌘O**. This pane renders it and live-reloads on save.

    ## Picking context

    - Hover any block — a small **Ask** button appears at its top-right.
    - Hover a heading for **Whole section**, which grabs everything down to the next heading of the same or higher level.
    - Or select text and click **Ask about selection** (or press **⌘⇧C**).

    Whatever you pick is sent as the exact Markdown source, not the rendered text.

    ```c
    // code blocks come across verbatim
    static Arena arena_init(void *base, size_t cap);
    ```

    ```mermaid
    graph LR
      A[Hover a diagram] --> B[Ask]
      B --> C[Chat panel]
    ```

    ## Shortcuts

    | Key | Action |
    | --- | --- |
    | ⌘J | Toggle chat panel |
    | ⌘⇧C | Send selection as context |
    | ⌘⇧N | New conversation |
    | ⌘R | Reload from disk |
    | ⌘, | API key and model |

    Add your Gemini API key with **⌘,** — it's stored in the login Keychain.
    """
}

/// Watches a single file, surviving the write-to-temp-then-rename dance most editors do.
final class FileWatcher {
    private var source: DispatchSourceFileSystemObject?
    private let url: URL
    private let onChange: () -> Void

    init(url: URL, onChange: @escaping () -> Void) {
        self.url = url
        self.onChange = onChange
        start()
    }

    private func start() {
        let fd = Darwin.open(url.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .rename, .delete],
            queue: .main
        )
        src.setEventHandler { [weak self] in
            guard let self, let src = self.source else { return }
            let flags = src.data
            self.onChange()
            if flags.contains(.rename) || flags.contains(.delete) {
                self.restart()
            }
        }
        src.setCancelHandler { close(fd) }
        source = src
        src.resume()
    }

    private func restart() {
        source?.cancel()
        source = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            guard let self else { return }
            self.start()
            self.onChange()
        }
    }

    deinit { source?.cancel() }
}
