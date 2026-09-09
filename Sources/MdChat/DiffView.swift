import SwiftUI

struct DiffView: View {
    let old: String
    let new: String

    var body: some View {
        let rows = Diff.lines(
            old: old.components(separatedBy: "\n"),
            new: new.components(separatedBy: "\n")
        )

        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(rows) { line in
                    row(for: line)
                }
            }
            .padding(.vertical, 4)
        }
        .frame(maxHeight: 280)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
    }

    @ViewBuilder
    private func row(for line: Diff.Line) -> some View {
        if case .gap = line.kind {
            Text(line.text)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
        } else {
            HStack(alignment: .top, spacing: 5) {
                Text(marker(line.kind))
                    .frame(width: 7, alignment: .leading)
                Text(line.text.isEmpty ? " " : line.text)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(tint(line.kind))
            .padding(.horizontal, 7)
            .padding(.vertical, 1)
            .background(wash(line.kind))
        }
    }

    private func marker(_ kind: Diff.Kind) -> String {
        switch kind {
        case .added: return "+"
        case .removed: return "−"
        default: return " "
        }
    }

    private func tint(_ kind: Diff.Kind) -> Color {
        switch kind {
        case .added: return .green
        case .removed: return .red
        default: return .primary.opacity(0.65)
        }
    }

    private func wash(_ kind: Diff.Kind) -> Color {
        switch kind {
        case .added: return .green.opacity(0.10)
        case .removed: return .red.opacity(0.10)
        default: return .clear
        }
    }
}
