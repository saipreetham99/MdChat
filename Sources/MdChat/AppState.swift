import AppKit
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
    /// Bumped to pull keyboard focus into the composer.
    @Published var composerFocusToken = 0
    @Published var editing = false
    @Published var isDirty = false
    /// First message still inside the context window; earlier ones aren't sent.
    @Published var oldestSent: UUID?

    /// Characters of history per request, roughly 6k tokens. Excerpts are the
    /// bulky part, so this is a cap on them more than on the prose.
    private let historyBudget = 24_000

    @Published var modelID: String {
        didSet { UserDefaults.standard.set(modelID, forKey: "modelID") }
    }
    @Published var apiKey: String = ""

    @Published var appearance: Appearance {
        didSet {
            UserDefaults.standard.set(appearance.rawValue, forKey: "appearance")
            applyAppearance()
        }
    }

    private var watcher: FileWatcher?
    private var streamTask: Task<Void, Never>?

    private init() {
        modelID = UserDefaults.standard.string(forKey: "modelID") ?? "gemini-flash-latest"
        apiKey = Keychain.read() ?? ""
        let saved = UserDefaults.standard.string(forKey: "appearance") ?? ""
        appearance = Appearance(rawValue: saved) ?? .system
    }

    /// Setting it on NSApp covers the SwiftUI chrome and the web view, which maps
    /// its effective appearance onto the preview's prefers-color-scheme queries.
    func applyAppearance() {
        NSApplication.shared.appearance = appearance.nsAppearance
    }

    func cycleAppearance() {
        appearance = appearance.next
    }

    // MARK: - Document

    func open(url: URL) {
        watcher = nil
        isDirty = false
        fileURL = url
        reload(force: true)
        watcher = FileWatcher(url: url) { [weak self] in
            self?.reload()
        }
    }

    /// `force` is the ⌘R path: it discards unsaved edits on purpose.
    func reload(force: Bool = false) {
        guard let url = fileURL else { return }
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            if text == markdown {
                isDirty = false
                return
            }
            if isDirty && !force {
                errorText = "\(url.lastPathComponent) changed on disk. ⌘R reloads and discards your edits."
                return
            }
            markdown = text
            isDirty = false
            errorText = nil
        } catch {
            errorText = "Couldn't read \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    // MARK: - Editing

    func toggleEditing() {
        editing.toggle()
        PreviewBridge.shared.focusPreview()
        PreviewBridge.shared.setView(editing ? "edit" : "preview")
    }

    func bufferChanged(_ text: String) {
        markdown = text
        isDirty = true
    }

    func save() {
        guard let url = fileURL else {
            errorText = "Nothing open to save. ⌘O first."
            return
        }
        Task {
            guard let text = await PreviewBridge.shared.readBuffer() else { return }
            do {
                // Atomic write; the watcher sees the rename and re-arms itself.
                try text.write(to: url, atomically: true, encoding: .utf8)
                markdown = text
                isDirty = false
                errorText = nil
            } catch {
                errorText = "Save failed: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Chat

    func toggleChat() {
        withAnimation(.easeOut(duration: 0.18)) { chatVisible.toggle() }
        if chatVisible {
            // Anything selected comes along, so selecting and opening the panel
            // is one step instead of two.
            PreviewBridge.shared.captureSelectionOnly()
            composerFocusToken += 1
        } else {
            PreviewBridge.shared.focusPreview()
        }
    }

    func attach(context: String) {
        let trimmed = context.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        pendingContext = trimmed
        chatVisible = true
        composerFocusToken += 1
    }

    func saveKey(_ key: String) {
        apiKey = key
        Keychain.write(key)
    }

    func send(_ prompt: String) {
        let question = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !isSending else { return }
        guard !apiKey.isEmpty else {
            errorText = "Add a Gemini API key first (\u{2318},)."
            showSettings = true
            return
        }

        messages.append(ChatMessage(role: .user, text: question, context: pendingContext))
        pendingContext = nil
        errorText = nil

        // Build the turns before the placeholder goes in; an empty model turn is rejected.
        let turns = contextWindow()

        let placeholder = ChatMessage(role: .model, text: "")
        let id = placeholder.id
        messages.append(placeholder)
        isSending = true

        let key = apiKey
        let model = modelID
        let system = Prompt.system(documentName: fileURL?.lastPathComponent ?? "untitled.md")

        streamTask = Task { [weak self] in
            do {
                for try await delta in Gemini.stream(apiKey: key, model: model, system: system, turns: turns) {
                    guard let self else { return }
                    guard let i = self.index(of: id) else { break }   // bubble was cleared
                    self.messages[i].text += delta
                }
            } catch {
                if !(error is CancellationError) {
                    self?.errorText = error.localizedDescription
                }
            }
            guard let self else { return }
            // Nothing arrived (error or immediate stop): drop the empty bubble.
            if let i = self.index(of: id), self.messages[i].text.isEmpty {
                self.messages.remove(at: i)
            }
            self.isSending = false
            self.streamTask = nil
        }
    }

    /// Newest-first walk that keeps whole turns until the budget runs out. The
    /// current question always goes, however big its excerpt.
    private func contextWindow() -> [Gemini.Turn] {
        var kept: [ChatMessage] = []
        var used = 0

        for msg in messages.reversed() {
            let wire = onTheWire(msg)
            if !kept.isEmpty, used + wire.count > historyBudget { break }
            kept.append(msg)
            used += wire.count
        }

        var ordered = Array(kept.reversed())
        // The API wants the conversation to open on a user turn.
        while ordered.first?.role == .model { ordered.removeFirst() }

        oldestSent = ordered.count < messages.count ? ordered.first?.id : nil
        return ordered.map { Gemini.Turn(role: $0.role.rawValue, text: onTheWire($0)) }
    }

    private func onTheWire(_ msg: ChatMessage) -> String {
        guard msg.role == .user, let ctx = msg.context else { return msg.text }
        return "From the document I'm reading:\n\n\(ctx)\n\n---\n\n\(msg.text)"
    }

    func stop() {
        streamTask?.cancel()
        streamTask = nil
        isSending = false
    }

    func newConversation() {
        stop()
        messages.removeAll()
        oldestSent = nil
        errorText = nil
    }

    private func index(of id: UUID) -> Int? {
        messages.firstIndex { $0.id == id }
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
