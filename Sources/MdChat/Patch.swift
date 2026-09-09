import Foundation

/// Where a piece of context came from in the source, plus what it looked like,
/// so a patch can be verified before it's written.
struct SourceAnchor: Equatable {
    var startLine: Int
    var endLine: Int        // exclusive
    var original: String
}

enum Patch {
    /// Models like to wrap a whole answer in a fence even when told not to.
    static func clean(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let lines = text.components(separatedBy: "\n")
        if lines.count >= 2,
           lines[0].hasPrefix("```"),
           let last = lines.last?.trimmingCharacters(in: .whitespaces),
           last.hasPrefix("```") {
            text = lines.dropFirst().dropLast().joined(separator: "\n")
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The only place a patch is allowed to land: an exact line-slice match, or
    /// exactly one match elsewhere in the file. Ambiguity refuses.
    static func locate(_ anchor: SourceAnchor, in lines: [String]) -> Range<Int>? {
        let start = anchor.startLine
        let end = min(anchor.endLine, lines.count)
        if start >= 0, start < end,
           lines[start..<end].joined(separator: "\n") == anchor.original {
            return start..<end
        }

        let needle = anchor.original.components(separatedBy: "\n")
        guard !needle.isEmpty, needle.count <= lines.count else { return nil }

        var found: Range<Int>?
        for offset in 0...(lines.count - needle.count) {
            if Array(lines[offset..<(offset + needle.count)]) == needle {
                if found != nil { return nil }   // moved *and* duplicated: refuse
                found = offset..<(offset + needle.count)
            }
        }
        return found
    }
}

enum Diff {
    enum Kind { case same, removed, added, gap }

    struct Line: Identifiable {
        let id: Int
        let kind: Kind
        let text: String
    }

    /// Standard LCS backtrack. Sections are tens of lines, so the quadratic
    /// table is cheaper than the code to avoid it — with a bail-out for abuse.
    static func lines(old: [String], new: [String]) -> [Line] {
        let n = old.count, m = new.count
        guard n * m <= 250_000 else { return wholesale(old: old, new: new) }

        var table = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        if n > 0 && m > 0 {
            for i in stride(from: n - 1, through: 0, by: -1) {
                for j in stride(from: m - 1, through: 0, by: -1) {
                    table[i][j] = old[i] == new[j]
                        ? table[i + 1][j + 1] + 1
                        : max(table[i + 1][j], table[i][j + 1])
                }
            }
        }

        var out: [Line] = []
        var id = 0
        var i = 0, j = 0

        func push(_ kind: Kind, _ text: String) {
            out.append(Line(id: id, kind: kind, text: text))
            id += 1
        }

        while i < n && j < m {
            if old[i] == new[j] {
                push(.same, old[i]); i += 1; j += 1
            } else if table[i + 1][j] >= table[i][j + 1] {
                push(.removed, old[i]); i += 1
            } else {
                push(.added, new[j]); j += 1
            }
        }
        while i < n { push(.removed, old[i]); i += 1 }
        while j < m { push(.added, new[j]); j += 1 }

        return collapse(out)
    }

    private static func wholesale(old: [String], new: [String]) -> [Line] {
        var out: [Line] = []
        var id = 0
        for line in old { out.append(Line(id: id, kind: .removed, text: line)); id += 1 }
        for line in new { out.append(Line(id: id, kind: .added, text: line)); id += 1 }
        return out
    }

    /// Long unchanged stretches become a single "unchanged" marker.
    private static func collapse(_ rows: [Line], context: Int = 2) -> [Line] {
        var out: [Line] = []
        var id = 0
        var run: [Line] = []

        func flushRun() {
            guard !run.isEmpty else { return }
            if run.count <= context * 2 + 1 {
                for line in run { out.append(Line(id: id, kind: .same, text: line.text)); id += 1 }
            } else {
                for line in run.prefix(context) {
                    out.append(Line(id: id, kind: .same, text: line.text)); id += 1
                }
                let hidden = run.count - context * 2
                out.append(Line(id: id, kind: .gap, text: "\(hidden) unchanged line\(hidden == 1 ? "" : "s")"))
                id += 1
                for line in run.suffix(context) {
                    out.append(Line(id: id, kind: .same, text: line.text)); id += 1
                }
            }
            run.removeAll()
        }

        for row in rows {
            if case .same = row.kind {
                run.append(row)
            } else {
                flushRun()
                out.append(Line(id: id, kind: row.kind, text: row.text))
                id += 1
            }
        }
        flushRun()
        return out
    }
}
