import SwiftUI
import WebKit
import UIKit

// MARK: - MarkdownSheet
//
// Full-screen rich rendering of a message: tables, code blocks, lists, links,
// blockquotes — everything native Text can't do. Renders via WKWebView + the
// bundled marked.js (offline). The markdown is passed as base64 to dodge all
// JS-string escaping pitfalls (backticks, quotes, </script>, unicode).

struct MarkdownSheet: View {
    let title: String
    let content: String
    /// True while the full body is still being lazily fetched (server-truncated
    /// message). Shows a small spinner over the preview until the body lands.
    var loading: Bool = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            MarkdownWebView(markdown: content)
                .ignoresSafeArea(edges: .bottom)
                .overlay(alignment: .top) {
                    if loading {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("正在加载完整内容…").font(.system(size: 12))
                        }
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(.regularMaterial, in: Capsule())
                        .padding(.top, 8)
                    }
                }
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            UIPasteboard.general.string = content
                        } label: { Image(systemName: "doc.on.doc") }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("完成") { dismiss() }
                    }
                }
        }
    }
}

private struct MarkdownWebView: UIViewRepresentable {
    let markdown: String

    final class Coordinator { var loaded: String? }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let wv = WKWebView()
        wv.isOpaque = false
        wv.backgroundColor = .clear
        wv.scrollView.backgroundColor = .clear
        wv.scrollView.alwaysBounceVertical = true
        return wv
    }

    func updateUIView(_ wv: WKWebView, context: Context) {
        // Only (re)load when the markdown actually changes. updateUIView fires on
        // every parent re-render (an active chat re-renders the bubble constantly
        // via status frames / new messages); reloading each time reset the
        // WKWebView scroll to the top, so the sheet "couldn't scroll down".
        guard context.coordinator.loaded != markdown else { return }
        context.coordinator.loaded = markdown
        wv.loadHTMLString(html, baseURL: nil)
    }

    private var html: String {
        let marked = Bundle.main.url(forResource: "marked.min", withExtension: "js")
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        let b64 = Data(markdown.utf8).base64EncodedString()
        return """
        <!doctype html><html><head>
        <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1">
        <style>
        :root { color-scheme: light dark; }
        body { font: -apple-system-body, system-ui; margin: 0; padding: 16px;
               line-height: 1.6; word-wrap: break-word; -webkit-text-size-adjust: 100%;
               color: #181818; background: #ffffff; }
        @media (prefers-color-scheme: dark) {
          body { color: #e7e7e7; background: #1c1c1e; }
          pre, code { background: #2c2c2e !important; }
          th, td { border-color: #3a3a3c !important; }
          blockquote { color: #aaa; border-color: #3a3a3c; }
          a { color: #4ea1ff; }
        }
        h1,h2,h3 { line-height: 1.3; }
        a { color: #07c160; }
        pre { background: #f5f5f5; padding: 12px; border-radius: 8px; overflow-x: auto; }
        code { background: #f0f0f0; padding: 2px 5px; border-radius: 4px;
               font: 13px ui-monospace, Menlo, monospace; }
        pre code { background: none; padding: 0; }
        table { border-collapse: collapse; width: 100%; margin: 12px 0; display: block; overflow-x: auto; }
        th, td { border: 1px solid #ddd; padding: 6px 10px; text-align: left; }
        th { background: rgba(127,127,127,0.12); }
        blockquote { margin: 8px 0; padding-left: 12px; border-left: 3px solid #ddd; color: #666; }
        img { max-width: 100%; }
        </style></head>
        <body><article id="c"></article>
        <script>\(marked)</script>
        <script>
        try {
          var md = decodeURIComponent(escape(window.atob("\(b64)")));
          document.getElementById('c').innerHTML = marked.parse(md);
        } catch (e) {
          document.getElementById('c').textContent = "" + e;
        }
        </script></body></html>
        """
    }
}
