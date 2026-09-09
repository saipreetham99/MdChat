import SwiftUI
import WebKit

/// Lets menu commands talk to the live web view.
@MainActor
final class PreviewBridge {
    static let shared = PreviewBridge()
    weak var webView: WKWebView?

    func captureSelection() {
        webView?.evaluateJavaScript("window.captureSelection && window.captureSelection()")
    }

    /// Vim keys only arrive when the web view is first responder.
    func focusPreview() {
        guard let web = webView else { return }
        web.window?.makeFirstResponder(web)
    }
}

struct PreviewView: NSViewRepresentable {
    var markdown: String
    var onContext: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onContext: onContext) }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.userContentController.add(context.coordinator, name: "bridge")
        config.suppressesIncrementalRendering = false

        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = context.coordinator
        web.allowsMagnification = true

        guard let html = Bundle.module.url(forResource: "Resources/preview", withExtension: "html") else {
            web.loadHTMLString("<p>preview.html missing from bundle.</p>", baseURL: nil)
            return web
        }
        web.loadFileURL(html, allowingReadAccessTo: html.deletingLastPathComponent())

        context.coordinator.webView = web
        PreviewBridge.shared.webView = web
        return web
    }

    func updateNSView(_ web: WKWebView, context: Context) {
        context.coordinator.push(markdown)
    }

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        weak var webView: WKWebView?
        private let onContext: (String) -> Void
        private var ready = false
        private var pending: String?
        private var current: String?

        init(onContext: @escaping (String) -> Void) {
            self.onContext = onContext
        }

        func push(_ markdown: String) {
            guard markdown != current else { return }
            current = markdown
            guard ready, let web = webView else { pending = markdown; return }
            render(markdown, in: web)
        }

        private func render(_ markdown: String, in web: WKWebView) {
            let payload = (try? JSONSerialization.data(withJSONObject: [markdown]))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
            web.evaluateJavaScript("window.render(\(payload)[0])")
        }

        func webView(_ web: WKWebView, didFinish navigation: WKNavigation!) {
            ready = true
            if let md = pending ?? current {
                pending = nil
                render(md, in: web)
            }
        }

        func userContentController(_ controller: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            guard let dict = message.body as? [String: Any],
                  let text = dict["text"] as? String else { return }
            onContext(text)
        }

        // Open real links in the browser instead of inside the preview.
        func webView(_ web: WKWebView,
                     decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if action.navigationType == .linkActivated, let url = action.request.url {
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
            } else {
                decisionHandler(.allow)
            }
        }
    }
}
