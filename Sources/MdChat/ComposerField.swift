import AppKit
import SwiftUI

/// SwiftUI's vertical `TextField` submits on ⇧↩ and reserves ⌥↩ for a newline,
/// with no way to swap them. A chat composer wants the opposite, so this wraps
/// an NSTextView and decides what Return means itself.
struct ComposerField: NSViewRepresentable {
    @Binding var text: String
    @Binding var height: CGFloat
    var placeholder: String
    /// Changing this value pulls first-responder status to the composer.
    var focusToken: Int
    var onSubmit: () -> Void
    var onEscape: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    /// Six lines of draft, then it scrolls instead of growing.
    static let maxHeight: CGFloat = 156

    func makeNSView(context: Context) -> NSScrollView {
        let view = ComposerTextView()
        view.delegate = context.coordinator
        view.isRichText = false
        view.allowsUndo = true
        view.drawsBackground = false
        view.font = .systemFont(ofSize: NSFont.systemFontSize)
        view.textContainerInset = NSSize(width: 0, height: 3)
        view.placeholder = placeholder

        // Resizable in the vertical direction only, so the scroll view has
        // something taller than itself to scroll once the draft is long.
        view.minSize = NSSize(width: 0, height: 0)
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        view.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)

        let scroll = NSScrollView()
        scroll.documentView = view
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.verticalScrollElasticity = .allowed

        context.coordinator.textView = view
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? ComposerTextView else { return }
        context.coordinator.parent = self
        if view.string != text { view.string = text }
        view.placeholder = placeholder

        if context.coordinator.lastFocusToken != focusToken {
            context.coordinator.lastFocusToken = focusToken
            DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        }
        DispatchQueue.main.async { context.coordinator.syncHeight() }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposerField
        weak var textView: ComposerTextView?
        var lastFocusToken = Int.min

        init(_ parent: ComposerField) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let view = textView else { return }
            parent.text = view.string
            syncHeight()
        }

        /// Grow with the text up to the cap; past that the scroll view takes over.
        func syncHeight() {
            guard let view = textView,
                  let manager = view.layoutManager,
                  let container = view.textContainer else { return }
            manager.ensureLayout(for: container)
            let used = manager.usedRect(for: container).height + view.textContainerInset.height * 2
            let clamped = min(max(20, used), ComposerField.maxHeight)
            if abs(parent.height - clamped) > 0.5 { parent.height = clamped }
        }

        func textView(_ view: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                // Shift is read off the live event: AppKit routes both plain and
                // shifted Return here depending on the input source.
                let shift = NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false
                if shift {
                    view.insertNewlineIgnoringFieldEditor(nil)
                } else {
                    parent.onSubmit()
                }
                return true

            case #selector(NSResponder.insertLineBreak(_:)),
                 #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
                view.insertNewlineIgnoringFieldEditor(nil)
                return true

            case #selector(NSResponder.cancelOperation(_:)):
                parent.onEscape()
                return true

            default:
                return false
            }
        }
    }
}

final class ComposerTextView: NSTextView {
    var placeholder: String = "" {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty else { return }

        let attributes: [NSAttributedString.Key: Any] = [
            .font: font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize),
            .foregroundColor: NSColor.placeholderTextColor
        ]
        let origin = NSPoint(x: (textContainer?.lineFragmentPadding ?? 5),
                             y: textContainerInset.height)
        placeholder.draw(at: origin, withAttributes: attributes)
    }
}
