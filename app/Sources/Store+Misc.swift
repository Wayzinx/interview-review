import AVFoundation
import AppKit
import Foundation
import PDFKit
import UniformTypeIdentifiers
import UserNotifications

extension Store {
    // MARK: 通知

    func title(_ id: String) -> String { session(id)?.title ?? URL(fileURLWithPath: id).lastPathComponent }

    func postNotification(_ title: String, _ body: String, id: String?) {
        guard notify else { return }
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        c.sound = .default
        if let id { c.userInfo = ["session": id] }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
    }

    // MARK: 其它

    func setResume() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.pdf, .plainText, .rtf, UTType(filenameExtension: "md")!,
                                 UTType(filenameExtension: "docx")!, UTType(filenameExtension: "doc")!]
        p.message = "选择你的简历（PDF / Word / Markdown / 文本）"
        guard p.runModal() == .OK, let file = p.url else { return }
        // 统一转成文本：Claude 读不了 Word，DeepSeek 读不了 PDF
        let ext = file.pathExtension.lowercased()
        var text: String?
        switch ext {
        case "pdf":
            text = PDFDocument(url: file)?.string
        case "doc", "docx", "rtf":
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("resume-\(UUID().uuidString).txt")
            let t = Process()
            t.executableURL = URL(fileURLWithPath: "/usr/bin/textutil")
            t.arguments = ["-convert", "txt", "-output", tmp.path, file.path]
            try? t.run()
            t.waitUntilExit()
            text = try? String(contentsOf: tmp, encoding: .utf8)
            try? FileManager.default.removeItem(at: tmp)
        default:
            text = (try? String(contentsOf: file, encoding: .utf8)) ?? (try? String(contentsOf: file, encoding: .utf16))
        }
        guard let body = text?.trimmingCharacters(in: .whitespacesAndNewlines), body.count >= 30 else {
            alert = AppAlert(title: "读不出简历内容", message: "「\(file.lastPathComponent)」里提取不到文字（可能是扫描件或图片）。换一份能复制文字的 PDF / Word / Markdown。")
            return
        }
        let fm = FileManager.default
        try? fm.createDirectory(at: profileDir, withIntermediateDirectories: true)
        for old in (try? fm.contentsOfDirectory(atPath: profileDir.path)) ?? [] where old.hasPrefix("resume.") || old.hasPrefix("简历原件") {
            try? fm.removeItem(at: profileDir.appendingPathComponent(old))
        }
        let out = ext == "md" ? "resume.md" : "resume.txt"
        try? body.write(to: profileDir.appendingPathComponent(out), atomically: true, encoding: .utf8)
        try? fm.copyItem(at: file, to: profileDir.appendingPathComponent("简历原件.\(ext)"))
        defaults.set(file.lastPathComponent, forKey: "resumeOriginal")
        refresh()
    }

    func rename(_ s: Session, to name: String) {
        guard jobs[s.id] == nil, recording?.dir != s.url else {
            alert = AppAlert(title: "暂时不能重命名", message: "这场面试正在录音或处理中，完成后再改名。")
            return
        }
        var dest = dataRoot.appendingPathComponent(s.datePrefix + slug(name))
        var n = 2
        while FileManager.default.fileExists(atPath: dest.path), dest != s.url {
            dest = dataRoot.appendingPathComponent(s.datePrefix + slug(name) + "-\(n)")
            n += 1
        }
        guard dest != s.url else { return }
        do {
            try FileManager.default.moveItem(at: s.url, to: dest)
            jobErrors[s.id] = nil
            refresh()
            route = .session(dest.path)
        } catch {
            alert = AppAlert(title: "重命名失败", message: error.localizedDescription)
        }
    }

    func trash(_ s: Session) {
        try? FileManager.default.trashItem(at: s.url, resultingItemURL: nil)
        if route == .session(s.id) { route = .home }
        refresh()
    }

    func requestMic() {
        Task {
            if AVCaptureDevice.authorizationStatus(for: .audio) == .denied {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
            } else {
                _ = await AVCaptureDevice.requestAccess(for: .audio)
            }
            refresh()
        }
    }

    /// 申请"系统录音"权限：没问过就弹系统对话框；被拒绝过就打开系统设置
    func requestSystemAudio() {
        if readiness.systemAudio == 1 {
            NSWorkspace.shared.open(
                URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
            return
        }
        Task {
            _ = await AudioCapturePermission.request()
            refresh()
        }
    }

    /// 系统设置里开着、App 却拿不到权限：多半是旧签名留下的授权。清掉本 App 的旧记录，重新申请。
    func repairScreen() {
        let id = Bundle.main.bundleIdentifier ?? "local.interview-review.app"
        for service in ["AudioCapture", "ScreenCapture"] {
            let t = Process()
            t.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
            t.arguments = ["reset", service, id]
            try? t.run()
            t.waitUntilExit()
        }
        Task {
            _ = await AudioCapturePermission.request()
            refresh()
        }
    }

    func requestScreen() {
        if !CGRequestScreenCaptureAccess() {
            NSWorkspace.shared.open(
                URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
        }
        refresh()
    }
}
