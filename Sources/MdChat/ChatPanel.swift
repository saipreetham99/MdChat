import SwiftUI

struct ChatPanel: View {
    @EnvironmentObject var state: AppState
    @State private var draft = ""
    @FocusState private var composerFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            transcript
            Divider()
            composer
        }
        .background(.background)
        .onAppear { composerFocused = true }
        .onChange(of: state.composerFocusToken) { _ in composerFocused = true }
        // Escape hands the keyboard back to the preview's vim layer.
        .onExitCommand {
            composerFocused = false
            PreviewBridge.shared.focusPreview()
        }
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if state.messages.isEmpty {
                        Text("Pick a block, diagram, or heading in the document, then ask about it. ⌘⇧R asks for a rewrite instead.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .padding(.top, 8)
                    }
                    ForEach(state.messages) { msg in
                        if msg.id == state.oldestSent {
                            TrimMarker()
                        }
                        MessageRow(message: msg).id(msg.id)
                    }
                    if state.isSending, state.messages.last?.text.isEmpty ?? true {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Thinking…").foregroundStyle(.secondary).font(.callout)
                        }
                        .id("spinner")
                    }
                    if let err = state.errorText {
                        Text(err)
                            .font(.callout)
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: state.messages.count) { _ in
                if let last = state.messages.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            // Keep the tail in view as tokens land.
            .onChange(of: state.messages.last?.text) { _ in
                if let last = state.messages.last {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if state.sessionTokens > 0 {
                HStack(spacing: 6) {
                    Text("This conversation")
                    Text(Prices.money(state.sessionCost)).foregroundStyle(.primary)
                    Text("·")
                    Text("\(Prices.tokens(state.sessionTokens)) tokens")
                    Spacer()
                    Button("Costs") { state.showSettings = true }
                        .buttonStyle(.plain)
                        .underline()
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            if let ctx = state.pendingContext {
                ContextChip(text: ctx,
                            rewriting: state.rewriteMode,
                            lines: state.pendingAnchor,
                            clear: state.clearPendingContext)
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField(state.rewriteMode ? "How should this section change?"
                                            : "Ask about the document",
                          text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...6)
                    .focused($composerFocused)
                    .onSubmit(send)
                Button(action: state.isSending ? state.stop : send) {
                    Image(systemName: state.isSending ? "stop.circle.fill" : "arrow.up.circle.fill")
                        .font(.title3)
                }
                .buttonStyle(.plain)
                .disabled(!state.isSending && draft.trimmingCharacters(in: .whitespaces).isEmpty)
                .help(state.isSending ? "Stop generating" : "Send (↩)")
            }
            .padding(8)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(state.rewriteMode ? Color.accentColor
                                                    : Color(nsColor: .separatorColor))
            )
        }
        .padding(12)
    }

    private func send() {
        let text = draft
        draft = ""
        state.send(text)
    }
}

private struct MessageRow: View {
    @EnvironmentObject var state: AppState
    let message: ChatMessage

    private var isStreaming: Bool {
        state.isSending && state.messages.last?.id == message.id
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(message.patch != nil ? Color.accentColor : .secondary)

            if let ctx = message.context {
                Text(ctx)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.06),
                                in: RoundedRectangle(cornerRadius: 6))
            }

            if let anchor = message.patch {
                patchBody(anchor)
            } else if message.role == .model {
                MarkdownText(message.text)
            } else {
                Text(message.text)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if message.role == .model, !isStreaming, let usage = message.usage {
                Text(meter(usage))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// "1.2k in · 386 out · $0.0021", with ~ when the counts are estimated and
    /// a nudge when there's no rate to price them with.
    private func meter(_ usage: Usage) -> String {
        let tilde = usage.estimated ? "~" : ""
        var parts = ["\(tilde)\(Prices.tokens(usage.inputTokens)) in",
                     "\(Prices.tokens(usage.outputTokens)) out"]
        if let spend = state.cost(of: message) {
            parts.append(Prices.money(spend))
        } else {
            parts.append("unpriced model")
        }
        return parts.joined(separator: " · ")
    }

    private var label: String {
        if message.patch != nil { return "Proposed rewrite" }
        if message.role == .user { return "You" }
        if let id = message.providerID, let provider = Provider(rawValue: id) {
            return provider.displayName
        }
        return "Assistant"
    }

    /// A patch is shown as a diff and never written without a decision.
    @ViewBuilder
    private func patchBody(_ anchor: SourceAnchor) -> some View {
        if isStreaming {
            // Raw while streaming: parsing markdown on every token would crawl
            // for a long section, and a half-arrived diff is noise anyway.
            Text(message.text)
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            DiffView(old: anchor.original, new: Patch.clean(message.text))

            HStack(spacing: 8) {
                Text("lines \(anchor.startLine + 1)–\(anchor.endLine)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()

                if message.applied {
                    Label("Applied", systemImage: "checkmark")
                        .font(.caption2)
                        .foregroundStyle(.green)
                } else if message.discarded {
                    Text("Discarded")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    Button("Discard") { state.discardPatch(message.id) }
                        .buttonStyle(.plain)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Button("Apply") { state.applyPatch(message.id) }
                        .font(.caption2)
                        .help("Apply (⌘⌥↩)")
                }
            }
        }
    }
}

/// Sits above the oldest message still being sent to the model.
private struct TrimMarker: View {
    var body: some View {
        HStack(spacing: 8) {
            Divider()
            Text("older messages dropped from context")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize()
            Divider()
        }
        .frame(height: 12)
    }
}

private struct ContextChip: View {
    let text: String
    let rewriting: Bool
    let lines: SourceAnchor?
    let clear: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: rewriting ? "pencil.line" : "text.quote")
                .foregroundStyle(rewriting ? Color.accentColor : .secondary)
            VStack(alignment: .leading, spacing: 3) {
                if rewriting || lines != nil {
                    Text(header)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(rewriting ? Color.accentColor : .secondary)
                }
                Text(text)
                    .font(.system(size: 11, design: .monospaced))
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Button(action: clear) {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Clear attached context")
        }
        .padding(8)
        .background((rewriting ? Color.accentColor : Color.gray).opacity(0.10),
                    in: RoundedRectangle(cornerRadius: 8))
    }

    private var header: String {
        let range = lines.map { "lines \($0.startLine + 1)–\($0.endLine)" } ?? "no source range"
        return rewriting ? "REWRITING \(range)" : range.uppercased()
    }
}
