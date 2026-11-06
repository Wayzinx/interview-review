import AVFoundation
import AppKit
import Foundation
import PDFKit
import UniformTypeIdentifiers
import UserNotifications

extension Store {
    // MARK: 录音

    func newSessionDir(_ name: String) -> URL {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HHmm"
        let base = "\(f.string(from: Date()))_\(slug(name))"
        var url = dataRoot.appendingPathComponent(base)
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = dataRoot.appendingPathComponent("\(base)-\(n)")
            n += 1
        }
        return url
    }

    func slug(_ name: String) -> String {
        let s = name.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "[\\s/\\\\:]+", with: "-", options: .regularExpression)
        return s.isEmpty ? "面试" : s
    }

    func startError(_ error: Error) {
        switch error as? RecError {
        case .systemAudioDenied?:
            alert = AppAlert(
                title: "需要「系统录音」权限",
                message: "用来录电脑播放的声音（面试官），只录声音、不录屏幕。\n\n在 系统设置 → 隐私与安全性 → 录屏与系统录音 →「仅系统录音」里打开「面试复盘」。",
                settingsURL: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"))
        case .systemAudio(let why)?:
            alert = AppAlert(title: "没法录电脑的声音", message: "\(why)\n\n可以先用「录音测试」检查一下；还不行就把这段提示发给我。")
        case .screenCapture?:
            alert = AppAlert(
                title: "需要「屏幕与系统录音」权限",
                message: "用来录电脑播放的声音（面试官），不会录画面。\n\n在 系统设置 → 隐私与安全性 → 屏幕与系统录音 里打开「面试复盘」，然后退出并重新打开本 App。",
                settingsURL: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"))
        case .microphone?:
            alert = AppAlert(
                title: "需要麦克风权限",
                message: "在 系统设置 → 隐私与安全性 → 麦克风 里打开「面试复盘」。",
                settingsURL: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"))
        default:
            alert = AppAlert(title: "无法开始录音", message: error.localizedDescription)
        }
    }

    func startRecording(name: String) async {
        guard recorder == nil, soundCheck?.running != true else { return }
        let dir = newSessionDir(name)
        let r = Recorder(outDir: dir)
        r.onInterrupted = { err in
            Task { @MainActor in
                let s = Store.shared
                s.alert = AppAlert(title: "录音被系统中断", message: "\(err.localizedDescription)\n已录下的部分会保存。")
                await s.stopRecording()
            }
        }
        do {
            try await r.start()
        } catch {
            try? FileManager.default.removeItem(at: dir)
            startError(error)
            return
        }
        recorder = r
        recording = RecordingState(dir: dir, name: name, micName: r.micName)
        NSSound(named: "Tink")?.play()  // 本 App 的声音不会被录进去
        refresh()
        micAlerted = false
        meterTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { _ in
            Task { @MainActor in
                let s = Store.shared
                guard let r = s.recorder, s.recording != nil else { return }
                let snap = r.snapshot()
                s.recording?.snap = snap
                // 麦克风断流超过 8 秒还没恢复：发通知（面试时 App 多半不在前台）
                if snap.micSilentFor > 8, !s.micAlerted {
                    s.micAlerted = true
                    NSSound(named: "Basso")?.play()
                    s.postNotification("⚠️ 你的麦克风没在录音", "已经 8 秒没有麦克风数据，正在自动重连。检查麦克风是否被拔掉或静音。", id: nil)
                } else if snap.micSilentFor < 1 {
                    s.micAlerted = false
                }
            }
        }
    }

    func stopRecording(transcribe: Bool = true) async {
        guard let r = recorder else { return }
        recorder = nil
        meterTimer?.invalidate()
        meterTimer = nil
        let marks = recording?.markers ?? []
        let sum = await r.stop()
        saveMarkers(marks, in: sum.outDir)
        recording = nil
        NSSound(named: "Pop")?.play()
        refresh()
        let id = sum.outDir.path
        route = .session(id)
        var warn: [String] = []
        if sum.interviewerVoiced < 5 { warn.append("面试官那条轨几乎没有声音：会议软件的声音可能没被录到。") }
        if sum.meVoiced < 5 { warn.append("你的麦克风那条轨几乎没有声音：检查输入设备。") }
        if !warn.isEmpty && sum.seconds > 20 {
            alert = AppAlert(title: "录音可能不完整", message: warn.joined(separator: "\n"))
        }
        guard transcribe, sum.seconds > 1 else { return }
        if autoAnalyze, sum.seconds > 60 { pendingAnalyze.insert(id) }
        if askContext, sum.seconds > 60 { contextPromptFor = id }
        self.transcribe(id)
    }

    /// 全局快捷键 / 菜单栏：没在录就开始（名字之后可以改），在录就结束
    func toggleRecording() {
        Task {
            if isRecording {
                await stopRecording()
            } else {
                await startRecording(name: "面试")
                if isRecording && !NSApp.isActive { postNotification("开始录音", "按 ⌃⌥⌘R 结束，⌃⌥⌘M 标记没答好的地方", id: nil) }
            }
        }
    }

    /// 标记"这里没答好"，复盘时会重点分析
    func addMarker() {
        guard let r = recorder, recording != nil else { return }
        let t = max(0, r.snapshot().elapsed - 3)  // 反应过来再按，往前挪 3 秒
        recording?.markers.append(t)
        saveMarkers(recording?.markers ?? [], in: r.outDir)
        NSSound(named: "Morse")?.play()
    }

    func saveMarkers(_ marks: [Double], in dir: URL) {
        guard !marks.isEmpty, let d = try? JSONSerialization.data(withJSONObject: marks.map { ["t": $0] }) else { return }
        try? d.write(to: dir.appendingPathComponent("markers.json"))
    }

    // MARK: 录音测试

    func runSoundCheck() async {
        guard recorder == nil, soundCheck?.running != true else { return }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ir-check-\(UUID().uuidString)")
        let r = Recorder(outDir: dir)
        soundCheck = SoundCheck()
        do {
            try await r.start()
        } catch {
            soundCheck = nil
            try? FileManager.default.removeItem(at: dir)
            startError(error)
            return
        }
        soundCheck?.micName = r.micName
        // 用另一个进程播提示音，模拟"对方说话"（本 App 自己的声音不会被录）
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
            p.arguments = ["/System/Library/Sounds/Glass.aiff"]
            try? p.run()
        }
        let start = Date()
        while Date().timeIntervalSince(start) < 6 {
            try? await Task.sleep(nanoseconds: 100_000_000)
            let s = r.snapshot()
            soundCheck?.progress = Date().timeIntervalSince(start) / 6
            soundCheck?.systemPeak = max(soundCheck?.systemPeak ?? -160, s.interviewerDB)
            soundCheck?.micPeak = max(soundCheck?.micPeak ?? -160, s.meDB)
        }
        _ = await r.stop()
        try? FileManager.default.removeItem(at: dir)
        soundCheck?.running = false
        refresh()
    }

    // MARK: 崩溃恢复

    func recoverInterrupted() {
        let broken = sessions.filter(\.needsRecovery)
        guard !broken.isEmpty else { return }
        Task.detached {
            let restored = broken.map { ($0.id, RecordingRecovery.recover($0.url)) }
            await MainActor.run {
                let s = Store.shared
                s.refresh()
                let mins = restored.map { $0.1 }.reduce(0, +) / 60
                s.alert = AppAlert(
                    title: "已恢复上次中断的录音",
                    message: "上次录音没有正常结束（App 退出或电脑关机），已从备份恢复约 \(Int(mins.rounded(.up))) 分钟录音，正在转写。")
                for (id, secs) in restored where secs > 1 {
                    if s.autoAnalyze && secs > 60 { s.pendingAnalyze.insert(id) }
                    s.transcribe(id)
                }
                if let first = restored.first { s.route = .session(first.0) }
            }
        }
    }

}
