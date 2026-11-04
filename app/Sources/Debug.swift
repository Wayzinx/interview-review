import AVFoundation
import AppKit
import WebKit

/// 开发自测用，正常启动时什么都不做。环境变量：
///   IR_ROUTE=record|home|<会话目录名>   IR_TAB=0/1（报告/对话稿）
///   IR_ROUTE=bank:weaknesses|bank:questions
///   IR_ACTION=transcribe|analyze|followup|exportpdf   启动后对当前会话触发任务
///   IR_QUESTION=<追问内容>  IR_PDF=<导出路径>
///   IR_SNAPSHOT_MID=<png>  IR_MID_DELAY=<秒>   任务进行中截一张
///   IR_SNAPSHOT=<png>      任务结束（或 4 秒后）截图并退出
@MainActor
enum DebugSnapshot {
    static func runIfRequested() {
        let env = ProcessInfo.processInfo.environment
        if env["IR_TAB"] == nil { UserDefaults.standard.removeObject(forKey: "debugTab") }
        if let out = env["IR_READINESS_OUT"] {
            // 诊断权限：从 LaunchServices 启动时，检查的是 App 自己的授权
            let r = "screen=\(CGPreflightScreenCaptureAccess()) mic=\(AVCaptureDevice.authorizationStatus(for: .audio).rawValue)"
            try? r.write(toFile: out, atomically: true, encoding: .utf8)
            exit(0)
        }
        guard let out = env["IR_SNAPSHOT"] else { return }
        let store = Store.shared
        var sessionID: String?
        switch env["IR_ROUTE"] ?? "home" {
        case "record": store.route = .record
        case "home": store.route = .home
        case let b where b.hasPrefix("bank:"): store.route = .bank(String(b.dropFirst(5)))
        case "settings":
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            }
        case let name:
            sessionID = dataRoot.appendingPathComponent(name).path
            store.route = .session(sessionID!)
        }
        if let t = env["IR_TAB"] { UserDefaults.standard.set(Int(t), forKey: "debugTab") }
        if let p = env["IR_PROVIDER"] { store.provider = p }
        if let k = env["IR_DS_KEY"] { store.saveDeepSeekKey(k) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            for w in NSApp.windows { w.contentView?.superview.map(flattenVibrancy) }
            if env["IR_ACTION"] == "testmodel", sessionID == nil { store.testModel() }
            if env["IR_ACTION"] == "soundcheck" { Task { await store.runSoundCheck() } }
            if let id = sessionID {
                switch env["IR_ACTION"] {
                case "transcribe": store.transcribe(id)
                case "analyze": store.analyze(id)
                case "followup": store.followUp(id, env["IR_QUESTION"] ?? "这场面试我最该先补哪块？")
                case "testmodel": store.testModel()
                default: break
                }
            }
        }
        if env["IR_ACTION"] == "exportpdf", let pdf = env["IR_PDF"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                let wv = NSApp.windows.compactMap { $0.contentView.map(allWebViews) }.flatMap { $0 }.first
                let h = WebHandle()
                h.webView = wv
                h.exportPDF(to: URL(fileURLWithPath: pdf))
            }
        }
        if let mid = env["IR_SNAPSHOT_MID"] {
            let delay = Double(env["IR_MID_DELAY"] ?? "10") ?? 10
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { snap(to: mid) {} }
        }
        var waited = 0.0
        func poll() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                waited += 1
                let busy = !store.jobs.isEmpty || store.modelTest?.running == true || store.soundCheck?.running == true
                if waited < 4 || (env["IR_ACTION"] != nil && busy && waited < 900) {
                    return poll()
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {  // 等页面刷新
                    if let id = sessionID, let e = store.jobErrors[id] { print("JOB_ERROR: \(e)") }
                    if let t = store.modelTest { print("MODEL_TEST: ok=\(t.ok) \(t.message)") }
                    if let c = store.soundCheck { print("SOUND_CHECK: system=\(c.systemPeak)dB mic=\(c.micPeak)dB") }
                    if let out = env["IR_RESULT"] {
                        let c = store.soundCheck
                        try? "system=\(c?.systemPeak ?? -999) mic=\(c?.micPeak ?? -999) perm=\(AudioCapturePermission.status() ?? -1)"
                            .write(toFile: out, atomically: true, encoding: .utf8)
                    }
                    if env["IR_SCROLL_END"] != nil {
                        for w in NSApp.windows {
                            for wv in w.contentView.map(allWebViews) ?? [] {
                                wv.evaluateJavaScript("window.scrollTo(0, document.body.scrollHeight)")
                            }
                        }
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { snap(to: out) { exit(0) } }
                }
            }
        }
        poll()
    }

    private static func snap(to path: String, then: @escaping () -> Void) {
        // 最前面的普通窗口（设置窗口打开时就是它）
        let main = NSApp.orderedWindows.first { $0.isVisible && $0.canBecomeKey && $0.frame.width > 300 }
        guard let w = main, let root = w.contentView?.superview ?? w.contentView
        else { return then() }
        let rep = root.bitmapImageRepForCachingDisplay(in: root.bounds)!
        root.cacheDisplay(in: root.bounds, to: rep)
        let webs = allWebViews(in: root)
        var pending = webs.count
        func finish() {
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            then()
        }
        if pending == 0 { return finish() }
        for wv in webs {
            wv.takeSnapshot(with: nil) { img, _ in
                if let img {
                    NSGraphicsContext.saveGraphicsState()
                    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
                    img.draw(in: wv.convert(wv.bounds, to: root))
                    NSGraphicsContext.restoreGraphicsState()
                }
                pending -= 1
                if pending == 0 { finish() }
            }
        }
    }

    private static func flattenVibrancy(_ v: NSView) {
        if let e = v as? NSVisualEffectView { e.blendingMode = .withinWindow }
        v.subviews.forEach(flattenVibrancy)
    }

    private static func allWebViews(in v: NSView) -> [WKWebView] {
        (v as? WKWebView).map { [$0] } ?? v.subviews.flatMap(allWebViews)
    }
}
