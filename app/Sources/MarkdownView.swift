import AppKit
import SwiftUI
import WebKit

/// 让外面拿到 WKWebView 做导出。
@MainActor
final class WebHandle: ObservableObject {
    weak var webView: WKWebView?

    /// 按打印排版（浅色、分页）导出 PDF。
    func exportPDF(to url: URL) {
        guard let wv = webView, let window = wv.window else { return }
        let info = NSPrintInfo.shared.copy() as! NSPrintInfo
        info.jobDisposition = .save
        info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = url
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.topMargin = 36
        info.bottomMargin = 36
        info.leftMargin = 36
        info.rightMargin = 36
        let op = wv.printOperation(with: info)
        op.showsPrintPanel = false
        op.showsProgressPanel = false
        op.view?.frame = wv.bounds
        op.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
    }
}

/// 用 WKWebView + marked.js 渲染报告/对话稿。时间戳 [hh:mm:ss] 变成可点击的跳转播放链接；
/// playhead 不为空时高亮对话稿里正在播放的那句。
struct MarkdownView: NSViewRepresentable {
    var markdown: String
    var chat: Bool
    var playhead: Double? = nil
    var handle: WebHandle? = nil
    var baseURL: URL? = nil
    /// 内容更新后滚到底（追问页：新回答在最下面）
    var scrollToEnd = false
    var onSeek: (Double) -> Void
    /// 点了指向本地文件的链接（比如题库里的"报告"）
    var onFile: ((URL) -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let wv = WKWebView()
        wv.navigationDelegate = context.coordinator
        wv.setValue(false, forKey: "drawsBackground")
        context.coordinator.webView = wv
        wv.loadHTMLString(Self.template, baseURL: baseURL)
        return wv
    }

    func updateNSView(_ wv: WKWebView, context: Context) {
        context.coordinator.onSeek = onSeek
        context.coordinator.onFile = onFile
        handle?.webView = wv
        context.coordinator.render(markdown, chat: chat, toEnd: scrollToEnd)
        context.coordinator.highlight(playhead)
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        weak var webView: WKWebView?
        var onSeek: (Double) -> Void = { _ in }
        var onFile: ((URL) -> Void)?
        private var ready = false
        private var pending: (String, Bool, Bool)?
        private var shown: (String, Bool)?
        private var lastHead: Double?

        func render(_ md: String, chat: Bool, toEnd: Bool = false) {
            if let s = shown, s.0 == md, s.1 == chat { return }
            guard ready, let wv = webView else {
                pending = (md, chat, toEnd)
                return
            }
            shown = (md, chat)
            lastHead = nil
            let json = (try? JSONSerialization.data(withJSONObject: [md], options: []))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
            wv.evaluateJavaScript("render(\(json)[0], \(chat), \(toEnd))")
        }

        func highlight(_ t: Double?) {
            guard ready, let wv = webView else { return }
            let v = t ?? -1
            if let l = lastHead, abs(l - v) < 0.4 { return }
            lastHead = v
            wv.evaluateJavaScript("highlight(\(v))")
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            ready = true
            if let p = pending {
                pending = nil
                render(p.0, chat: p.1, toEnd: p.2)
            }
        }

        func webView(
            _ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            guard let url = action.request.url else { return decisionHandler(.allow) }
            if url.scheme == "seek" {
                if let s = Double(url.host ?? "") { onSeek(s) }
                return decisionHandler(.cancel)
            }
            if url.isFileURL, action.navigationType == .linkActivated {
                onFile?(url)
                return decisionHandler(.cancel)
            }
            if url.scheme == "http" || url.scheme == "https" {
                NSWorkspace.shared.open(url)
                return decisionHandler(.cancel)
            }
            decisionHandler(.allow)
        }
    }

    static let template: String = {
        let js = Bundle.main.url(forResource: "marked.min", withExtension: "js")
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        return """
            <!doctype html><html><head><meta charset="utf-8"><style>
            :root { color-scheme: light dark; --fg:#1d1d1f; --muted:#6e6e73; --line:#e3e3e8; --accent:#0a6cff;
                    --soft:#f4f4f7; --iv:#f1f1f4; --me:#e7f0ff; --mark:#fff4d6; --flag:#fff1dc; --flagline:#ff9500; }
            @media (prefers-color-scheme: dark) { :root { --fg:#ececf0; --muted:#9a9aa1; --line:#38383c; --accent:#4da3ff;
                    --soft:#26262a; --iv:#2a2a2e; --me:#16314f; --mark:#3d3420; --flag:#3a2a12; --flagline:#ff9f0a; } }
            html, body { background: transparent; }
            body { font: 14px/1.75 -apple-system, "PingFang SC", "Helvetica Neue", sans-serif; color: var(--fg);
                   margin: 0 auto; padding: 18px 32px 80px; max-width: 920px; -webkit-font-smoothing: antialiased; }
            h1 { font-size: 21px; margin: 6px 0 14px; }
            h2 { font-size: 17px; margin: 30px 0 10px; padding-bottom: 6px; border-bottom: 1px solid var(--line); }
            h3 { font-size: 15px; margin: 24px 0 8px; padding: 8px 12px; background: var(--soft); border-radius: 8px; }
            h4 { font-size: 14px; margin: 16px 0 6px; color: var(--muted); }
            p, li { margin: 6px 0; } ul, ol { padding-left: 22px; }
            table { border-collapse: collapse; width: 100%; margin: 12px 0; font-size: 13px; }
            th, td { border: 1px solid var(--line); padding: 6px 10px; text-align: left; vertical-align: top; }
            th { background: var(--soft); font-weight: 600; }
            td.nw, th.nw { white-space: nowrap; }
            blockquote { margin: 12px 0; padding: 10px 14px; border-left: 3px solid var(--accent); background: var(--soft);
                         border-radius: 0 8px 8px 0; }
            blockquote p { margin: 4px 0; }
            blockquote.flag { border-left-color: var(--flagline); background: var(--flag); }
            code { background: var(--soft); padding: 1px 5px; border-radius: 4px; font: 12.5px ui-monospace, Menlo, monospace; }
            hr { border: 0; border-top: 1px solid var(--line); margin: 18px 0; }
            a { color: var(--accent); }
            a.ts { text-decoration: none; font-variant-numeric: tabular-nums; border-radius: 4px; padding: 0 2px; }
            a.ts:hover { background: var(--mark); }
            sub { color: var(--muted); }
            input[type=checkbox] { margin-right: 6px; }
            body.chat p.turn { padding: 8px 14px; border-radius: 12px; margin: 10px 0; max-width: 82%; width: fit-content;
                               transition: box-shadow .2s; }
            body.chat p.turn.iv { background: var(--iv); border-top-left-radius: 4px; }
            body.chat p.turn.me { background: var(--me); margin-left: auto; border-top-right-radius: 4px; }
            body.chat p.turn.now { box-shadow: 0 0 0 2px var(--accent); }
            body.chat p.turn > strong:first-child { display: block; font-size: 12px; color: var(--muted); font-weight: 500; }
            body.chat p.turn.me > strong:first-child { text-align: right; }
            @media print {
              :root { --fg:#111; --muted:#555; --line:#ccc; --accent:#0a5ad4; --soft:#f3f3f5; --iv:#f1f1f4; --me:#e7f0ff;
                      --flag:#fff1dc; --flagline:#ff9500; }
              body { max-width: none; padding: 0; -webkit-print-color-adjust: exact; }
              h2, h3 { break-after: avoid; } tr, blockquote, p.turn { break-inside: avoid; }
            }
            </style></head><body><div id="c"></div>
            <script>\(js)</script>
            <script>
            let nowEl = null;
            function render(md, chat, toEnd) {
              document.body.className = chat ? 'chat' : '';
              let html = marked.parse(md, { gfm: true });
              html = html.replace(/\\[(\\d{2}):(\\d{2}):(\\d{2})\\]/g,
                (m, h, mi, s) => `<a class="ts" title="从这里播放" href="seek://${(+h) * 3600 + (+mi) * 60 + (+s)}">${m}</a>`);
              const c = document.getElementById('c');
              c.innerHTML = html;
              nowEl = null;
              if (window._chat !== chat) { window.scrollTo(0, 0); window._chat = chat; }
              if (toEnd) window.scrollTo(0, document.body.scrollHeight);
              c.querySelectorAll('blockquote').forEach(b => { if (b.textContent.includes('🚩')) b.classList.add('flag'); });
              // 短单元格（维度名、分数、日期、状态）不换行，长内容照常折行
              c.querySelectorAll('td, th').forEach(td => { if (td.textContent.trim().length <= 10) td.classList.add('nw'); });
              if (chat) c.querySelectorAll('p').forEach(p => {
                const st = p.firstElementChild;
                if (!st || st.tagName !== 'STRONG' || p.firstChild !== st) return;
                const who = st.textContent;
                const nx = st.nextSibling;
                if (nx && nx.nodeType === 3) nx.textContent = nx.textContent.replace(/^[：:]\\s*/, '');
                if (/面试官/.test(who)) p.classList.add('turn', 'iv');
                else if (/我|说话人/.test(who)) p.classList.add('turn', 'me');
                const a = st.querySelector('a.ts');
                if (a) p.dataset.t = a.getAttribute('href').slice(7);
              });
            }
            function highlight(t) {
              let cur = null;
              if (t >= 0) for (const p of document.querySelectorAll('p.turn')) {
                if (+p.dataset.t <= t + 0.6) cur = p; else break;
              }
              if (cur === nowEl) return;
              if (nowEl) nowEl.classList.remove('now');
              nowEl = cur;
              if (!cur) return;
              cur.classList.add('now');
              const r = cur.getBoundingClientRect();
              if (r.top < 40 || r.bottom > innerHeight - 40) cur.scrollIntoView({ block: 'center', behavior: 'smooth' });
            }
            </script></body></html>
            """
    }()
}
