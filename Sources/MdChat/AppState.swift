import AppKit
import Foundation
import SwiftUI

struct ChatMessage: Identifiable, Equatable {
    enum Role: String { case user, model }
    let id = UUID()
    let role: Role
    var text: String
    var context: String? = nil
    /// Where a user message's excerpt came from.
    var anchor: SourceAnchor? = nil
    /// Set on a model reply that is a proposed replacement for that excerpt.
    var patch: SourceAnchor? = nil
    var applied = false
    var discarded = false
    /// Which backend and model produced a model reply — kept per message so
    /// switching provider mid-conversation doesn't reprice old replies.
    var providerID: String? = nil
    var modelID: String? = nil
    var usage: Usage? = nil
}

@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    @Published var fileURL: URL?
    @Published var markdown: String = AppState.welcome
    @Published var chatVisible = true
    @Published var pendingContext: String?
    @Published var pendingAnchor: SourceAnchor?
    /// The next send is a rewrite request rather than a question.
    @Published var rewriteMode = false
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

    /// Cumulative spend across launches, per provider.
    @Published private(set) var lifetimeCost: [String: Double] = [:]
    @Published private(set) var lifetimeTokens: [String: Int] = [:]

    @Published var provider: Provider {
        didSet { UserDefaults.standard.set(provider.rawValue, forKey: "provider") }
    }
    @Published private(set) var keys: [String: String] = [:]
    @Published private(set) var modelIDs: [String: String] = [:]

    var apiKey: String { key(for: provider) }
    var modelID: String { model(for: provider) }

    func key(for provider: Provider) -> String { keys[provider.rawValue] ?? "" }

    func model(for provider: Provider) -> String {
        let stored = modelIDs[provider.rawValue] ?? ""
        return stored.isEmpty ? provider.defaultModel : stored
    }

    @Published var zoom: Double {
        didSet {
            UserDefaults.standard.set(zoom, forKey: "zoom")
            PreviewBridge.shared.setZoom(zoom)
        }
    }

    @Published var appearance: Appearance {
        didSet {
            UserDefaults.standard.set(appearance.rawValue, forKey: "appearance")
            applyAppearance()
        }
    }

    private var watcher: FileWatcher?
    private var streamTask: Task<Void, Never>?

    private init() {
        let savedProvider = UserDefaults.standard.string(forKey: "provider") ?? ""
        provider = Provider(rawValue: savedProvider) ?? .gemini

        zoom = UserDefaults.standard.object(forKey: "zoom") as? Double ?? 1.0

        let savedAppearance = UserDefaults.standard.string(forKey: "appearance") ?? ""
        appearance = Appearance(rawValue: savedAppearance) ?? .system

        for candidate in Provider.allCases {
            keys[candidate.rawValue] = Keychain.read(candidate.rawValue) ?? ""
            modelIDs[candidate.rawValue] =
                UserDefaults.standard.string(forKey: "model." + candidate.rawValue) ?? ""
            lifetimeCost[candidate.rawValue] =
                UserDefaults.standard.double(forKey: "spend." + candidate.rawValue)
            lifetimeTokens[candidate.rawValue] =
                UserDefaults.standard.integer(forKey: "spentTokens." + candidate.rawValue)
        }
    }

    /// Setting it on NSApp covers the SwiftUI chrome and the web view, which maps
    /// its effective appearance onto the preview's prefers-color-scheme queries.
    func applyAppearance() {
        NSApplication.shared.appearance = appearance.nsAppearance
    }

    func cycleAppearance() {
        appearance = appearance.next
    }

    // MARK: - Zoom

    /// Geometric steps, so in and out are exact inverses.
    func zoomIn() { zoom = clampZoom(zoom * 1.1) }
    func zoomOut() { zoom = clampZoom(zoom / 1.1) }
    func zoomReset() { zoom = 1.0 }

    var zoomPercent: Int { Int((zoom * 100).rounded()) }

    private func clampZoom(_ value: Double) -> Double {
        min(3.0, max(0.5, (value * 100).rounded() / 100))
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

    func attach(context: String, start: Int? = nil, end: Int? = nil) {
        let trimmed = context.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        pendingContext = trimmed
        if let start, let end, end > start {
            pendingAnchor = SourceAnchor(startLine: start, endLine: end, original: context)
        } else {
            pendingAnchor = nil
        }
        chatVisible = true
        composerFocusToken += 1
    }

    /// ⌘⇧R: the next message describes an edit to the attached excerpt.
    func startRewrite() {
        if pendingAnchor == nil { PreviewBridge.shared.captureSelectionOnly() }
        rewriteMode = true
        chatVisible = true
        composerFocusToken += 1
    }

    func cancelRewrite() {
        rewriteMode = false
    }

    func clearPendingContext() {
        pendingContext = nil
        pendingAnchor = nil
        rewriteMode = false
    }

    func saveCredentials(for provider: Provider, key: String, model: String) {
        let trimmedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        keys[provider.rawValue] = trimmedKey
        Keychain.write(trimmedKey, account: provider.rawValue)

        let trimmedModel = model.trimmingCharacters(in: .whitespaces)
        modelIDs[provider.rawValue] = trimmedModel
        UserDefaults.standard.set(trimmedModel, forKey: "model." + provider.rawValue)
    }

    func send(_ prompt: String) {
        let question = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !isSending else { return }
        guard !apiKey.isEmpty else {
            errorText = "Add a \(provider.displayName) API key first (\u{2318},)."
            showSettings = true
            return
        }

        let asRewrite = rewriteMode
        if asRewrite && pendingAnchor == nil {
            errorText = "Select the section you want rewritten first."
            return
        }

        let anchor = pendingAnchor
        messages.append(ChatMessage(role: .user, text: question,
                                    context: pendingContext, anchor: anchor))
        pendingContext = nil
        pendingAnchor = nil
        rewriteMode = false
        errorText = nil

        // Build the turns before the placeholder goes in; an empty model turn is rejected.
        // A rewrite is a one-shot: history would drag old prose into the replacement.
        let turns: [LLM.Turn]
        if asRewrite {
            let request = messages[messages.count - 1]
            turns = [LLM.Turn(role: "user", text: onTheWire(request))]
            oldestSent = request.id      // a rewrite deliberately sends nothing else
        } else {
            turns = contextWindow()
        }

        let placeholder = ChatMessage(role: .model, text: "",
                                      patch: asRewrite ? anchor : nil,
                                      providerID: provider.rawValue,
                                      modelID: modelID)
        let id = placeholder.id
        messages.append(placeholder)
        isSending = true

        let name = fileURL?.lastPathComponent ?? "untitled.md"
        let backend = provider
        let key = apiKey
        let model = modelID
        let system = asRewrite ? Prompt.rewrite(documentName: name)
                               : Prompt.system(documentName: name)

        let promptChars = turns.reduce(0) { $0 + $1.text.count } + system.count

        streamTask = Task { [weak self] in
            do {
                let replies = LLM.stream(provider: backend, apiKey: key, model: model,
                                         system: system, turns: turns)
                for try await event in replies {
                    guard let self else { return }
                    guard let i = self.index(of: id) else { break }   // bubble was cleared
                    switch event {
                    case .text(let delta):
                        self.messages[i].text += delta
                    case .usage(let usage):
                        self.messages[i].usage = usage
                    }
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
            } else if let i = self.index(of: id) {
                // A stopped or older stream may never send a usage frame.
                if self.messages[i].usage == nil {
                    self.messages[i].usage = Usage.estimate(
                        inputChars: promptChars,
                        outputChars: self.messages[i].text.count
                    )
                }
                if let usage = self.messages[i].usage {
                    self.record(usage, provider: backend, model: model)
                }
            }
            self.isSending = false
            self.streamTask = nil
        }
    }

    /// Newest-first walk that keeps whole turns until the budget runs out. The
    /// current question always goes, however big its excerpt.
    private func contextWindow() -> [LLM.Turn] {
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
        return ordered.map { LLM.Turn(role: $0.role.rawValue, text: onTheWire($0)) }
    }

    private func onTheWire(_ msg: ChatMessage) -> String {
        guard msg.role == .user, let ctx = msg.context else { return msg.text }
        return "From the document I'm reading:\n\n\(ctx)\n\n---\n\n\(msg.text)"
    }

    // MARK: - Cost

    private func record(_ usage: Usage, provider: Provider, model: String) {
        let spend = Prices.rate(provider: provider, model: model).cost(usage)
        lifetimeCost[provider.rawValue] = (lifetimeCost[provider.rawValue] ?? 0) + spend
        lifetimeTokens[provider.rawValue] = (lifetimeTokens[provider.rawValue] ?? 0) + usage.total
        UserDefaults.standard.set(lifetimeCost[provider.rawValue],
                                  forKey: "spend." + provider.rawValue)
        UserDefaults.standard.set(lifetimeTokens[provider.rawValue],
                                  forKey: "spentTokens." + provider.rawValue)
    }

    /// Priced per message with its own provider and model, not today's setting.
    func cost(of message: ChatMessage) -> Double? {
        guard let usage = message.usage,
              let id = message.providerID,
              let provider = Provider(rawValue: id),
              let model = message.modelID else { return nil }
        let rate = Prices.rate(provider: provider, model: model)
        return rate.isSet ? rate.cost(usage) : nil
    }

    var sessionCost: Double {
        messages.reduce(0) { $0 + (cost(of: $1) ?? 0) }
    }

    var sessionTokens: Int {
        messages.reduce(0) { $0 + ($1.usage?.total ?? 0) }
    }

    /// nil restores the bundled rate card for that model.
    func setRateOverride(_ rate: Rate?, provider: Provider, model: String) {
        Prices.setOverride(rate, provider: provider, model: model)
        objectWillChange.send()
    }

    func resetLifetime(for provider: Provider) {
        lifetimeCost[provider.rawValue] = 0
        lifetimeTokens[provider.rawValue] = 0
        UserDefaults.standard.set(0.0, forKey: "spend." + provider.rawValue)
        UserDefaults.standard.set(0, forKey: "spentTokens." + provider.rawValue)
    }

    // MARK: - Patching

    /// Writes a proposed replacement into the buffer, but only where it still
    /// matches what was sent. Goes through CodeMirror, so ⌘Z undoes it.
    func applyPatch(_ id: UUID) {
        guard let i = messages.firstIndex(where: { $0.id == id }),
              let anchor = messages[i].patch else { return }

        let replacement = Patch.clean(messages[i].text)
        guard !replacement.isEmpty else { return }

        let lines = markdown.components(separatedBy: "\n")
        guard let range = Patch.locate(anchor, in: lines) else {
            errorText = "That section moved or changed since you asked. Re-select it and try again."
            return
        }

        PreviewBridge.shared.applyPatch(start: range.lowerBound,
                                        end: range.upperBound,
                                        text: replacement)
        messages[i].applied = true
        isDirty = true
        errorText = nil
    }

    func discardPatch(_ id: UUID) {
        guard let i = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[i].discarded = true
    }

    /// ⌘⌥↩ acts on the newest reply that's still awaiting a decision.
    func applyLatestPatch() {
        guard let msg = messages.last(where: {
            $0.patch != nil && !$0.applied && !$0.discarded && !$0.text.isEmpty
        }) else {
            errorText = "No pending rewrite to apply."
            return
        }
        applyPatch(msg.id)
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
        rewriteMode = false
        pendingAnchor = nil
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

    Add an API key with **⌘,** — Gemini or Muse Spark, stored in the login Keychain.
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
