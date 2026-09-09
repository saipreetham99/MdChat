import AppKit
import SwiftUI

/// Renders a model reply as blocks. `AttributedString` handles inline spans
/// well enough, but fences, headings, lists and quotes need real layout.
struct MarkdownText: View {
    private let source: String

    init(_ source: String) { self.source = source }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(MarkdownParser.blocks(in: source)) { block in
                view(for: block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func view(for block: MarkdownBlock) -> some View {
        switch block.kind {
        case .heading(let level):
            Text(MarkdownInline.render(block.text))
                .font(.system(size: headingSize(level), weight: .semibold))
                .padding(.top, level <= 2 ? 4 : 2)

        case .paragraph:
            Text(MarkdownInline.render(block.text))
                .fixedSize(horizontal: false, vertical: true)

        case .bullet:
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("•").foregroundStyle(.secondary)
                Text(MarkdownInline.render(block.text))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, CGFloat(block.indent) * 14)

        case .numbered(let label):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(label).foregroundStyle(.secondary).monospacedDigit()
                Text(MarkdownInline.render(block.text))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, CGFloat(block.indent) * 14)

        case .quote:
            HStack(alignment: .top, spacing: 8) {
                RoundedRectangle(cornerRadius: 1)
                    .fill(.tertiary)
                    .frame(width: 2)
                Text(MarkdownInline.render(block.text))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

        case .rule:
            Divider().padding(.vertical, 2)

        case .code(let language):
            CodeBlock(code: block.text, language: language)
        }
    }

    private func headingSize(_ level: Int) -> CGFloat {
        switch level {
        case 1: return 18
        case 2: return 16
        case 3: return 14.5
        default: return 13
        }
    }
}

private struct CodeBlock: View {
    let code: String
    let language: String?
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language ?? "code")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(copied ? "Copied" : "Copy", action: copy)
                    .buttonStyle(.plain)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.top, 5)
            .padding(.bottom, 2)

            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(size: 11.5, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
    }
}

// MARK: - Parsing

struct MarkdownBlock: Identifiable {
    enum Kind: Equatable {
        case paragraph
        case heading(Int)
        case bullet
        case numbered(String)
        case quote
        case code(String?)
        case rule
    }

    /// Positional, not a UUID: replies stream, so a stable id per block keeps
    /// SwiftUI from tearing down and rebuilding every view on each token.
    let id: Int
    let kind: Kind
    let text: String
    let indent: Int
}

enum MarkdownParser {
    static func blocks(in source: String) -> [MarkdownBlock] {
        var out: [MarkdownBlock] = []
        var paragraph: [String] = []
        var next = 0

        func emit(_ kind: MarkdownBlock.Kind, _ text: String, indent: Int = 0) {
            out.append(MarkdownBlock(id: next, kind: kind, text: text, indent: indent))
            next += 1
        }

        func flush() {
            guard !paragraph.isEmpty else { return }
            emit(.paragraph, paragraph.joined(separator: " "))
            paragraph.removeAll()
        }

        let lines = source.components(separatedBy: "\n")
        var i = 0

        while i < lines.count {
            let raw = lines[i]
            let line = raw.trimmingCharacters(in: .whitespaces)

            // Fenced code. An unterminated fence is normal mid-stream, so the
            // remainder is treated as code rather than falling back to prose.
            if line.hasPrefix("```") || line.hasPrefix("~~~") {
                flush()
                let fence = String(line.prefix(3))
                let info = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var body: [String] = []
                i += 1
                while i < lines.count {
                    if lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
                        i += 1
                        break
                    }
                    body.append(lines[i])
                    i += 1
                }
                emit(.code(info.isEmpty ? nil : info), body.joined(separator: "\n"))
                continue
            }

            if line.isEmpty {
                flush()
                i += 1
                continue
            }

            if line == "---" || line == "***" || line == "___" {
                flush()
                emit(.rule, "")
                i += 1
                continue
            }

            if let level = headingLevel(line) {
                flush()
                emit(.heading(level),
                     String(line.dropFirst(level)).trimmingCharacters(in: .whitespaces))
                i += 1
                continue
            }

            if line.hasPrefix(">") {
                flush()
                emit(.quote, String(line.dropFirst()).trimmingCharacters(in: .whitespaces))
                i += 1
                continue
            }

            if let item = listItem(raw) {
                flush()
                emit(item.kind, item.text, indent: item.indent)
                i += 1
                continue
            }

            paragraph.append(line)
            i += 1
        }

        flush()
        return out
    }

    private static func headingLevel(_ line: String) -> Int? {
        var count = 0
        for ch in line {
            if ch == "#" { count += 1 } else { break }
        }
        guard (1...6).contains(count), line.dropFirst(count).first == " " else { return nil }
        return count
    }

    private static func listItem(_ raw: String)
        -> (kind: MarkdownBlock.Kind, text: String, indent: Int)?
    {
        let leading = raw.prefix { $0 == " " || $0 == "\t" }.count
        let indent = min(leading / 2, 3)
        let line = raw.trimmingCharacters(in: .whitespaces)

        for marker in ["- ", "* ", "+ "] where line.hasPrefix(marker) {
            return (.bullet, String(line.dropFirst(2)), indent)
        }

        let digits = line.prefix { $0.isNumber }
        if !digits.isEmpty, digits.count <= 3 {
            let after = line.dropFirst(digits.count)
            if after.hasPrefix(". ") || after.hasPrefix(") ") {
                return (.numbered(digits + "."), String(after.dropFirst(2)), indent)
            }
        }
        return nil
    }
}

enum MarkdownInline {
    static func render(_ text: String) -> AttributedString {
        guard var attr = try? AttributedString(
            markdown: text,
            options: .init(
                interpretedSyntax: .inlineOnlyPreservingWhitespace,
                failurePolicy: .returnPartiallyParsedIfPossible
            )
        ) else {
            return AttributedString(text)
        }

        // SwiftUI doesn't style `inline code` on its own.
        var codeRanges: [Range<AttributedString.Index>] = []
        for run in attr.runs where run.inlinePresentationIntent?.contains(.code) == true {
            codeRanges.append(run.range)
        }
        for range in codeRanges {
            attr[range].font = .system(size: 11.5, design: .monospaced)
        }
        return attr
    }
}
