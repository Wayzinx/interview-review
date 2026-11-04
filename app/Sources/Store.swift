import AVFoundation
import AppKit
import Foundation
import PDFKit
import UniformTypeIdentifiers
import UserNotifications

let irRoot: URL = {
    if let p = Bundle.main.object(forInfoDictionaryKey: "IRRoot") as? String { return URL(fileURLWithPath: p) }
    return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("interview-review")
}()
let homeDir = FileManager.default.homeDirectoryForCurrentUser
/// 面试数据目录：默认 ~/Interviews，可用环境变量 INTERVIEW_HOME 覆盖（和命令行工具一致）
let dataRoot: URL = {
    if let h = ProcessInfo.processInfo.environment["INTERVIEW_HOME"], !h.isEmpty {
        return URL(fileURLWithPath: (h as NSString).expandingTildeInPath)
    }
    return homeDir.appendingPathComponent("Interviews")
}()
let profileDir = dataRoot.appendingPathComponent("_profile")
let bankDir = dataRoot.appendingPathComponent("_bank")
let modelDir = homeDir.appendingPathComponent(".cache/modelscope/models/iic--SenseVoiceSmall")

// MARK: - 会话

struct Session: Identifiable, Hashable {
    let url: URL
    var id: String { url.path }
    let title: String
    let date: Date?
    let audioFiles: [URL]
    let transcriptMTime: Date?
    let reportMTime: Date?
    let followupsMTime: Date?
    let score: Double?
    let needsRecovery: Bool

    var hasAudio: Bool { !audioFiles.isEmpty }
    var hasTranscript: Bool { transcriptMTime != nil }
    var hasReport: Bool { reportMTime != nil }
    /// 单轨（导入的混音，或只剩一条轨）：说话人靠声纹区分，可能判反
    var isMixed: Bool { audioFiles.count == 1 }
    var transcriptURL: URL { url.appendingPathComponent("transcript.md") }
    var reportURL: URL { url.appendingPathComponent("report.md") }
    var contextURL: URL { url.appendingPathComponent("context.md") }
    var followupsURL: URL { url.appendingPathComponent("followups.md") }
    var markersURL: URL { url.appendingPathComponent("markers.json") }

    var status: String {
        hasReport ? "已复盘" : hasTranscript ? "已转写" : needsRecovery ? "待恢复" : hasAudio ? "仅录音" : "空"
    }

    /// 目录名前缀 "yyyy-MM-dd_HHmm_"
    var datePrefix: String {
        let n = url.lastPathComponent
        return date != nil ? String(n.prefix(16)) : ""
    }

    private static let nameFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HHmm"
        return f
    }()

    static func load(_ url: URL, score: (URL, Date?) -> Double?) -> Session {
        let fm = FileManager.default
        func mtime(_ name: String) -> Date? {
            (try? fm.attributesOfItem(atPath: url.appendingPathComponent(name).path))?[.modificationDate] as? Date
        }
        let name = url.lastPathComponent
        var title = name
        var date: Date?
        if name.count > 16, let d = nameFmt.date(from: String(name.prefix(15))) {
            date = d
            title = String(name.dropFirst(16))
        }
        let audio = ["interviewer.m4a", "me.m4a", "mixed.m4a"].map { url.appendingPathComponent($0) }
            .filter { fm.fileExists(atPath: $0.path) }
        let report = mtime("report.md")
        return Session(
            url: url, title: title, date: date, audioFiles: audio,
            transcriptMTime: mtime("transcript.md"), reportMTime: report, followupsMTime: mtime("followups.md"),
            score: score(url.appendingPathComponent("report.md"), report),
            needsRecovery: RecordingRecovery.needsRecovery(url))
    }
}

enum Route: Hashable {
    case home, record
    case session(String)
    case bank(String)  // "weaknesses" / "questions"
}

// MARK: - 后台任务

enum JobKind { case importing, transcribe, analyze, followup }

struct Job {
    var kind: JobKind
    var started = Date()
    var progress: Double?
    var line = ""
    var steps = 0
}

struct AppAlert: Identifiable {
    let id = UUID()
    var title: String
    var message: String
    var settingsURL: URL?
}

struct RecordingState {
    var dir: URL
    var name: String
    var snap = RecSnapshot()
    var markers: [Double] = []
    var micName = ""
}

/// 面试前的录音测试结果
struct SoundCheck {
    var running = true
    var progress = 0.0
    var systemPeak: Float = -160
    var micPeak: Float = -160
    var micName = ""
    var systemOK: Bool { systemPeak > -50 }
    var micOK: Bool { micPeak > -50 }
}

/// 设置里"测试连接"的结果
struct ModelTest {
    var running: Bool
    var ok: Bool
    var message: String
}

/// 首页 / 设置里的"准备情况"
struct Readiness: Equatable {
    var mic: AVAuthorizationStatus = .notDetermined
    /// 系统录音（仅声音）权限：0 已授权，1 拒绝，2 未询问，nil 查不到（当作可用）
    var systemAudio: Int?
    var screen: Bool { systemAudio == nil || systemAudio == 0 }
    var model = false
    var claude = false
    var resume = false
    var allGood: Bool { mic == .authorized && screen && model && claude }
}

/// 启动子进程，按行回调 stdout+stderr（主线程），结束回调退出码。
@discardableResult
func runProcess(
    _ exe: String, _ args: [String], env: [String: String], cwd: URL? = nil,
    onLine: @escaping (String) -> Void, done: @escaping (Int32) -> Void
) throws -> Process {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: exe)
    p.arguments = args
    p.environment = env
    if let cwd { p.currentDirectoryURL = cwd }
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    p.standardInput = FileHandle.nullDevice
    let reader = pipe.fileHandleForReading
    var buf = Data()
    let lock = NSLock()
    func drain(_ d: Data, final: Bool) {
        lock.lock()
        buf.append(d)
        var lines: [String] = []
        while let nl = buf.firstIndex(of: 0x0A) {
            lines.append(String(decoding: buf[buf.startIndex..<nl], as: UTF8.self))
            buf.removeSubrange(buf.startIndex...nl)
        }
        if final && !buf.isEmpty {
            lines.append(String(decoding: buf, as: UTF8.self))
            buf.removeAll()
        }
        lock.unlock()
        if !lines.isEmpty { DispatchQueue.main.async { lines.forEach(onLine) } }
    }
    reader.readabilityHandler = { h in
        let d = h.availableData
        if d.isEmpty { h.readabilityHandler = nil } else { drain(d, final: false) }
    }
    p.terminationHandler = { proc in
        reader.readabilityHandler = nil
        drain(reader.readDataToEndOfFile(), final: true)
        DispatchQueue.main.async { done(proc.terminationStatus) }
    }
    try p.run()
    return p
}

private func baseEnv() -> [String: String] {
    let user = NSUserName()
    var env = [
        "HOME": homeDir.path, "USER": user, "LOGNAME": user, "SHELL": "/bin/zsh", "LANG": "en_US.UTF-8",
        "PATH": "\(homeDir.path)/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
        "PYTHONUNBUFFERED": "1",
    ]
    if let h = ProcessInfo.processInfo.environment["INTERVIEW_HOME"] { env["INTERVIEW_HOME"] = h }
    return env
}

/// 本机 Claude Code 可执行文件（GUI App 没有终端的 PATH，按常见安装位置找）
func claudeBinary() -> String? {
    let candidates = [
        "\(homeDir.path)/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude",
        "\(homeDir.path)/.claude/local/claude", "\(homeDir.path)/.npm-global/bin/claude",
    ]
    return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
}

private let pyCLI = irRoot.appendingPathComponent(".venv/bin/interview-py").path

// MARK: - Store

@MainActor
final class Store: ObservableObject {
    static let shared = Store()

    @Published var sessions: [Session] = []
    @Published var route: Route? = .home
    @Published var jobs: [String: Job] = [:] { didSet { updateActivity() } }
    @Published var jobErrors: [String: String] = [:]
    @Published var recording: RecordingState? { didSet { recordingChanged(oldValue) } }
    @Published var alert: AppAlert?
    @Published var soundCheck: SoundCheck?
    @Published var output: AudioDevices.Output?
    @Published var readiness = Readiness()
    @Published var resumeFile: String?
    /// 录完后自动弹出"岗位信息"的会话
    @Published var contextPromptFor: String?
    @Published var renaming: Session?
    /// 主窗口关掉后，从菜单栏 / 通知重新打开（由 MenuBarLabel 注入 openWindow）
    var openMainWindow: (() -> Void)?

    // 设置
    @Published var account: String { didSet { defaults.set(account, forKey: "account") } }
    /// 复盘用哪家模型："claude"（本机 Claude Code，或 cca 账号）或 "deepseek"（API key）
    @Published var provider: String { didSet { defaults.set(provider, forKey: "provider"); refresh() } }
    @Published var deepseekModel: String { didSet { defaults.set(deepseekModel, forKey: "deepseekModel") } }
    @Published private(set) var deepseekKeySaved = Keychain.read() != nil
    @Published var modelTest: ModelTest?
    @Published var autoAnalyze: Bool { didSet { defaults.set(autoAnalyze, forKey: "autoAnalyze") } }
    @Published var askContext: Bool { didSet { defaults.set(askContext, forKey: "askContext") } }
    @Published var notify: Bool { didSet { defaults.set(notify, forKey: "notify") } }
    let accounts: [String]

    var isRecording: Bool { recording != nil }

    private let defaults = UserDefaults.standard
    private var recorder: Recorder?
    private var processes: [String: Process] = [:]
    /// 转写完要自动复盘的会话
    @Published private(set) var pendingAnalyze: Set<String> = []
    /// 正在显示"岗位信息"弹窗的会话：等它关掉再开始自动复盘
    private var contextSheetOpen: String?
    private var pollTimer: Timer?
    private var meterTimer: Timer?
    private var micAlerted = false
    private var activity: NSObjectProtocol?
    private var scoreCache: [String: (Date, Double?)] = [:]

    private init() {
        let accDir = homeDir.appendingPathComponent(".claude-accounts")
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: accDir.path)) ?? [])
            .filter { $0.hasSuffix(".token") }.map { String($0.dropLast(6)) }.sorted()
        accounts = names
        let d = UserDefaults.standard
        let saved = d.string(forKey: "account")
        account = saved.flatMap { $0.isEmpty || names.contains($0) ? $0 : nil } ?? ""
        provider = d.string(forKey: "provider") ?? "claude"
        deepseekModel = d.string(forKey: "deepseekModel") ?? "deepseek-v4-pro"
        autoAnalyze = d.object(forKey: "autoAnalyze") as? Bool ?? true
        askContext = d.object(forKey: "askContext") as? Bool ?? true
        notify = d.object(forKey: "notify") as? Bool ?? true
        try? FileManager.default.createDirectory(at: dataRoot, withIntermediateDirectories: true)
        refresh()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            Task { @MainActor in Store.shared.refresh() }
        }
        recoverInterrupted()
    }

    func session(_ id: String) -> Session? { sessions.first { $0.id == id } }

    func refresh() {
        let fm = FileManager.default
        let dirs = (try? fm.contentsOfDirectory(at: dataRoot, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        let list = dirs.filter {
            !$0.lastPathComponent.hasPrefix("_") && !$0.lastPathComponent.hasPrefix(".")
                && ((try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false)
        }.map { Session.load($0, score: score) }.sorted { $0.url.lastPathComponent > $1.url.lastPathComponent }
        if list != sessions { sessions = list }
        let r = ((try? fm.contentsOfDirectory(atPath: profileDir.path)) ?? []).first { $0.hasPrefix("resume.") }
        let shown = r == nil ? nil : (defaults.string(forKey: "resumeOriginal") ?? r)
        if shown != resumeFile { resumeFile = shown }
        let o = AudioDevices.output()
        if o != output { output = o }
        let rd = Readiness(
            mic: AVCaptureDevice.authorizationStatus(for: .audio), systemAudio: AudioCapturePermission.status(),
            model: fm.fileExists(atPath: modelDir.path),
            claude: provider == "deepseek" ? deepseekKeySaved : (account.isEmpty ? claudeBinary() != nil : true),
            resume: r != nil)
        if rd != readiness { readiness = rd }
    }

    /// 从 report.md 里读"整体 x/5"，按修改时间缓存
    private func score(_ report: URL, _ mtime: Date?) -> Double? {
        guard let mtime else { return nil }
        if let c = scoreCache[report.path], c.0 == mtime { return c.1 }
        let text = (try? String(contentsOf: report, encoding: .utf8)) ?? ""
        var v: Double?
        if let m = text.range(of: #"整体[^0-9\n]{0,6}([0-9]+(\.[0-9]+)?)\s*/\s*5"#, options: .regularExpression) {
            let s = text[m]
            if let n = s.range(of: #"[0-9]+(\.[0-9]+)?(?=\s*/\s*5)"#, options: .regularExpression) { v = Double(s[n]) }
        }
        scoreCache[report.path] = (mtime, v)
        return v
    }

    // MARK: 防休眠 / Dock 角标

    private func updateActivity() {
        let busy = recording != nil || !jobs.isEmpty
        if busy, activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(
                options: [.idleSystemSleepDisabled, .suddenTerminationDisabled], reason: "面试录音 / 转写 / 复盘进行中")
        } else if !busy, let a = activity {
            ProcessInfo.processInfo.endActivity(a)
            activity = nil
        }
    }

    private func recordingChanged(_ old: RecordingState?) {
        if (old == nil) != (recording == nil) {
            NSApp.dockTile.badgeLabel = recording == nil ? nil : "REC"
            updateActivity()
        }
    }

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

    private func slug(_ name: String) -> String {
        let s = name.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "[\\s/\\\\:]+", with: "-", options: .regularExpression)
        return s.isEmpty ? "面试" : s
    }

    private func startError(_ error: Error) {
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

    private func saveMarkers(_ marks: [Double], in dir: URL) {
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

    // MARK: 导入

    func importFile() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.audiovisualContent]
        p.message = "选择面试录音或录屏（两个人的声音在同一个文件里也可以）"
        guard p.runModal() == .OK, let file = p.url else { return }
        importURL(file)
    }

    func importURL(_ file: URL) {
        let key = "import:\(file.path)"
        guard jobs[key] == nil else { return }
        jobs[key] = Job(kind: .importing, line: "导入 \(file.lastPathComponent)…")
        var out: [String] = []
        do {
            try runProcess(
                pyCLI, ["import", file.path, file.deletingPathExtension().lastPathComponent], env: baseEnv(),
                onLine: { out.append($0) },
                done: { code in
                    self.jobs[key] = nil
                    guard code == 0, let dir = out.last(where: { $0.hasPrefix("/") }) else {
                        self.alert = AppAlert(title: "导入失败", message: out.suffix(5).joined(separator: "\n"))
                        return
                    }
                    self.refresh()
                    self.route = .session(dir)
                    if self.autoAnalyze { self.pendingAnalyze.insert(dir) }
                    self.transcribe(dir)
                })
        } catch {
            jobs[key] = nil
            alert = AppAlert(title: "导入失败", message: error.localizedDescription)
        }
    }

    // MARK: 崩溃恢复

    private func recoverInterrupted() {
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

    // MARK: 转写

    func transcribe(_ id: String) {
        guard jobs[id] == nil else { return }
        jobErrors[id] = nil
        jobs[id] = Job(kind: .transcribe, progress: 0, line: "加载语音模型…")
        var tail: [String] = []
        do {
            processes[id] = try runProcess(
                pyCLI, ["transcribe", id], env: baseEnv(),
                onLine: { line in
                    if line.hasPrefix("PROGRESS "), let v = Double(line.dropFirst(9)) {
                        self.jobs[id]?.progress = v / 100
                    } else if !line.isEmpty, !line.contains("torchaudio"), !line.contains("ffmpeg") {
                        tail.append(line)
                        if !line.hasPrefix("/") && !line.hasPrefix(" ") { self.jobs[id]?.line = line }
                    }
                },
                done: { code in
                    self.jobs[id] = nil
                    self.processes[id] = nil
                    self.refresh()
                    if code == 15 {
                        self.pendingAnalyze.remove(id)
                        return
                    }
                    if code != 0 {
                        self.pendingAnalyze.remove(id)
                        self.jobErrors[id] = "转写失败：\n" + tail.suffix(6).joined(separator: "\n")
                        self.postNotification("转写失败", self.title(id), id: id)
                        return
                    }
                    if self.pendingAnalyze.contains(id) {
                        self.startPendingAnalyze(id)
                    } else {
                        self.postNotification("转写完成", self.title(id), id: id)
                    }
                })
        } catch {
            jobs[id] = nil
            jobErrors[id] = "转写失败：\(error.localizedDescription)"
        }
    }

    /// 转写完了，且岗位信息框已关：开始自动复盘
    private func startPendingAnalyze(_ id: String) {
        guard pendingAnalyze.contains(id), contextSheetOpen != id, jobs[id] == nil,
            session(id)?.hasTranscript == true
        else { return }
        pendingAnalyze.remove(id)
        analyze(id)
    }

    func contextSheet(opened id: String) {
        contextSheetOpen = id
        if contextPromptFor == id { contextPromptFor = nil }
    }

    func contextSheet(closed id: String) {
        if contextSheetOpen == id { contextSheetOpen = nil }
        refresh()
        startPendingAnalyze(id)
    }

    func swapSpeakers(_ id: String) {
        guard jobs[id] == nil else { return }
        var out: [String] = []
        _ = try? runProcess(
            pyCLI, ["swap", id], env: baseEnv(), onLine: { out.append($0) },
            done: { code in
                self.refresh()
                if code != 0 {
                    self.alert = AppAlert(title: "对调失败", message: out.suffix(4).joined(separator: "\n"))
                } else if self.session(id)?.hasReport == true {
                    self.alert = AppAlert(title: "已对调说话人", message: "复盘报告是按之前的角色写的，建议点「重新生成复盘」。")
                }
            })
    }

    // MARK: AI（复盘 / 追问）

    var providerName: String { provider == "deepseek" ? "DeepSeek" : "Claude" }
    var modelLabel: String {
        provider == "deepseek" ? "DeepSeek（\(deepseekModel)）"
            : account.isEmpty ? "Claude（本机 Claude Code）" : "Claude（cca 账号 \(account)）"
    }

    func saveDeepSeekKey(_ key: String) {
        let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if !Keychain.save(k) { alert = AppAlert(title: "保存失败", message: "没能写入钥匙串，再试一次。") }
        deepseekKeySaved = Keychain.read() != nil
        modelTest = nil
        refresh()
    }

    /// 组装一次无界面 Claude Code 调用：Claude 走本机 claude 命令（或 cca 多账号）；DeepSeek 直接跑 claude，
    /// 把模型后端指向 DeepSeek 的 Anthropic 兼容接口，用独立配置目录，不碰任何 Claude 账号。
    private func invocation(_ prompt: String, extra: [String]) -> (exe: String, args: [String], env: [String: String])? {
        var env = baseEnv()
        if provider == "deepseek" {
            guard let key = Keychain.read(), let exe = claudeBinary() else { return nil }
            prepareDeepSeekConfig()
            env["CLAUDE_CONFIG_DIR"] = homeDir.appendingPathComponent(".claude-deepseek").path
            env["ANTHROPIC_BASE_URL"] = "https://api.deepseek.com/anthropic"
            env["ANTHROPIC_AUTH_TOKEN"] = key
            env["ANTHROPIC_MODEL"] = deepseekModel
            env["ANTHROPIC_DEFAULT_OPUS_MODEL"] = deepseekModel
            env["ANTHROPIC_DEFAULT_SONNET_MODEL"] = deepseekModel
            env["ANTHROPIC_DEFAULT_HAIKU_MODEL"] = "deepseek-flash"
            env["CLAUDE_CODE_SUBAGENT_MODEL"] = "deepseek-flash"
            env["CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"] = "1"
            env["DISABLE_AUTOUPDATER"] = "1"
            env["API_TIMEOUT_MS"] = "600000"
            return (exe, ["-p", prompt, "--dangerously-skip-permissions"] + extra, env)
        }
        env["IR_PROMPT"] = prompt
        if account.isEmpty {
            // 本机已登录的 Claude Code（订阅或 API key 都行）。登录 shell 能拿到用户自己的 PATH 设置
            let cmd = #"claude -p "$IR_PROMPT" --dangerously-skip-permissions "# + extra.joined(separator: " ")
            return ("/bin/zsh", ["-lc", cmd], env)
        }
        // cca：~/.claude-accounts 多账号切换脚本
        env["IR_ACCOUNT"] = account
        let cmd = #"cca "$IR_ACCOUNT" -p "$IR_PROMPT" "# + extra.joined(separator: " ")
        return ("/bin/zsh", ["-lc", cmd], env)
    }

    /// DeepSeek 专用的 Claude Code 配置目录：共享 skills，跳过首启引导
    private func prepareDeepSeekConfig() {
        let fm = FileManager.default
        let dir = homeDir.appendingPathComponent(".claude-deepseek")
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let skills = dir.appendingPathComponent("skills")
        if (try? fm.destinationOfSymbolicLink(atPath: skills.path)) == nil, !fm.fileExists(atPath: skills.path) {
            try? fm.createSymbolicLink(at: skills, withDestinationURL: homeDir.appendingPathComponent(".claude/skills"))
        }
        let cfg = dir.appendingPathComponent(".claude.json")
        if !fm.fileExists(atPath: cfg.path) {
            try? #"{"hasCompletedOnboarding": true, "lastOnboardingVersion": "2.1.90"}"#.write(to: cfg, atomically: true, encoding: .utf8)
        }
    }

    private var missingModelMessage: String {
        provider == "deepseek"
            ? (claudeBinary() == nil ? "没找到 Claude Code（DeepSeek 模式也要用它）：先安装 https://claude.com/claude-code"
                : "还没填 DeepSeek API key：设置 → 复盘模型")
            : "没找到 claude 命令：先安装并登录 Claude Code（https://claude.com/claude-code）"
    }

    /// 401/402 这类错误 Claude Code 会重试 10 次（好几分钟），直接停掉并说人话
    private func fatalAPIError(_ status: Int) -> String? {
        switch status {
        case 401, 403:
            if provider == "deepseek" { return "DeepSeek API key 无效或已失效：设置 → 复盘模型，重新填一个" }
            return account.isEmpty ? "Claude Code 认证失败：在终端运行 claude 重新登录" : "cca 账号 \(account) 认证失败（token 失效），重新登录这个账号"
        case 402: return "DeepSeek 账户余额不足，去 platform.deepseek.com 充值后再试"
        default: return nil
        }
    }

    /// 后台跑一次 Claude Code（-p），解析 stream-json 更新进度，结束回调最终回答。
    private func runClaude(
        _ id: String, kind: JobKind, prompt: String, first: String,
        done: @escaping (_ ok: Bool, _ result: String?, _ error: String) -> Void
    ) {
        guard jobs[id] == nil else { return }
        guard let inv = invocation(prompt, extra: ["--output-format", "stream-json", "--verbose"]) else {
            jobErrors[id] = missingModelMessage
            return
        }
        jobErrors[id] = nil
        jobs[id] = Job(kind: kind, line: first)
        let dir = URL(fileURLWithPath: id)
        let log = dir.appendingPathComponent(kind == .analyze ? ".analysis.log" : ".followup.log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let logHandle = try? FileHandle(forWritingTo: log)
        var resultText: String?
        var isError = false
        var fatal: String?
        var tail: [String] = []
        do {
            processes[id] = try runProcess(
                inv.exe, inv.args, env: inv.env, cwd: dir,
                onLine: { line in
                    try? logHandle?.write(contentsOf: (line + "\n").data(using: .utf8)!)
                    guard line.hasPrefix("{"), let d = line.data(using: .utf8),
                        let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any]
                    else {
                        if !line.isEmpty, !line.contains("sk-ant"), !line.contains("sk-") { tail.append(line) }
                        return
                    }
                    switch obj["type"] as? String {
                    case "assistant":
                        let content = (obj["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
                        for c in content {
                            if let a = Self.describe(c) {
                                self.jobs[id]?.line = a
                                self.jobs[id]?.steps += 1
                            }
                        }
                    case "system" where obj["subtype"] as? String == "api_retry":
                        let status = obj["error_status"] as? Int ?? 0
                        if let f = self.fatalAPIError(status), fatal == nil {
                            fatal = f
                            self.processes[id]?.terminate()
                        } else {
                            self.jobs[id]?.line = "\(self.providerName) 接口暂时出错（\(status)），第 \(obj["attempt"] as? Int ?? 0) 次重试…"
                        }
                    case "result":
                        resultText = obj["result"] as? String
                        isError = (obj["is_error"] as? Bool) ?? false
                    default: break
                    }
                },
                done: { code in
                    try? logHandle?.close()
                    self.jobs[id] = nil
                    self.processes[id] = nil
                    self.refresh()
                    if let fatal {
                        done(false, nil, fatal)
                        return
                    }
                    if code == 15 { return }  // 用户取消
                    let ok = code == 0 && !isError && resultText != nil
                    var why = resultText ?? tail.suffix(4).joined(separator: "\n")
                    if why.isEmpty { why = "退出码 \(code)" }
                    if tail.contains(where: { $0.contains("出口 IP") && $0.contains("阻止") }) {
                        why = "代理出口 IP 校验没通过（cca 拒绝启动），检查代理后重试。\n" + why
                    }
                    done(ok, resultText, "\(why)\n\n详细日志：\(log.path)")
                })
        } catch {
            jobs[id] = nil
            jobErrors[id] = "无法启动 \(providerName)：\(error.localizedDescription)"
        }
    }

    /// 设置里的"测试连接"：问一句最简单的话，看模型通不通
    func testModel() {
        guard modelTest?.running != true else { return }
        guard let inv = invocation("只回复两个字：成功", extra: ["--output-format", "stream-json", "--verbose"]) else {
            modelTest = ModelTest(running: false, ok: false, message: missingModelMessage)
            return
        }
        modelTest = ModelTest(running: true, ok: false, message: "正在连接 \(modelLabel)…")
        let started = Date()
        var result: String?
        var isError = false
        var fatal: String?
        var proc: Process?
        do {
            proc = try runProcess(
                inv.exe, inv.args, env: inv.env, cwd: FileManager.default.temporaryDirectory,
                onLine: { line in
                    guard line.hasPrefix("{"), let d = line.data(using: .utf8),
                        let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any]
                    else { return }
                    if obj["type"] as? String == "system", obj["subtype"] as? String == "api_retry" {
                        let status = obj["error_status"] as? Int ?? 0
                        fatal = self.fatalAPIError(status) ?? "接口返回错误 \(status)"
                        proc?.terminate()
                    } else if obj["type"] as? String == "result" {
                        result = obj["result"] as? String
                        isError = obj["is_error"] as? Bool ?? false
                    }
                },
                done: { code in
                    let secs = Int(Date().timeIntervalSince(started))
                    if let fatal {
                        self.modelTest = ModelTest(running: false, ok: false, message: fatal)
                    } else if code == 0, !isError, let r = result {
                        self.modelTest = ModelTest(running: false, ok: true, message: "连接正常（\(secs) 秒），模型回复：\(r.prefix(20))")
                    } else {
                        self.modelTest = ModelTest(running: false, ok: false, message: "连接失败：\(result ?? "退出码 \(code)")")
                    }
                })
        } catch {
            modelTest = ModelTest(running: false, ok: false, message: "无法启动：\(error.localizedDescription)")
        }
    }

    func analyze(_ id: String) {
        let prompt = """
            使用 interview-review skill 复盘这场面试：\(id)
            （规则在 ~/.claude/skills/interview-review/SKILL.md；如果 skill 没有自动加载，先完整读这个文件再严格照做。）

            这是「面试复盘」App 在后台调用的：用户看不到这段对话，也没法回答问题。不要向用户提问，公司/岗位/JD/简历等上下文缺了就跳过；只读这个会话目录和 ~/Interviews 下的文件，不用看工具源码。按 skill 写好 report.md、更新题库和弱项档案后，只回复一句话总结。
            """
        runClaude(id, kind: .analyze, prompt: prompt,  first: "启动 \(modelLabel)…") { ok, _, err in
            let s = Store.shared
            let has = FileManager.default.fileExists(atPath: URL(fileURLWithPath: id).appendingPathComponent("report.md").path)
            if ok && has {
                let sc = s.session(id)?.score.map { " · 整体 \(String(format: "%g", $0))/5" } ?? ""
                s.postNotification("复盘完成", s.title(id) + sc, id: id)
            } else {
                s.jobErrors[id] = "生成复盘失败：\n\(err)"
                s.postNotification("复盘失败", s.title(id), id: id)
            }
        }
    }

    static let followupSuggestions = [
        "把得分最低的那道题，给我一个能直接说出口的满分答法",
        "扮演面试官，就我答得最差的题继续追问我，一次只问一个问题",
        "这场暴露的问题，帮我排个三天的针对性练习计划",
        "把我这场讲的项目经历整理成 STAR 结构，并补上该准备的数据",
    ]

    func followUp(_ id: String, _ question: String) {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        let prompt = """
            你是我的面试教练。先读这场面试的材料（存在才读）：\(id)/transcript.md（对话稿）、\(id)/report.md（复盘报告）、\(id)/followups.md（之前的追问记录）、\(id)/context.md（岗位信息），以及 ~/Interviews/_profile/ 下的简历。

            然后回答我的问题：
            \(q)

            要求：中文，直接、具体、能照着练。给示范答法时只用材料里出现过的真实经历，缺的数据用【补充：…】占位。如果我让你扮演面试官，就直接提问，一次只问一个问题。不要创建或修改任何文件，只输出回答本身。
            """
        runClaude(id, kind: .followup, prompt: prompt, first: "\(providerName) 正在思考…") { ok, result, err in
            let s = Store.shared
            guard ok, let answer = result else {
                s.jobErrors[id] = "追问失败：\n\(err)"
                return
            }
            let f = DateFormatter()
            f.dateFormat = "M月d日 HH:mm"
            let entry = "## 🙋 \(q)\n\n<sub>\(f.string(from: Date()))</sub>\n\n\(answer)\n\n---\n\n"
            let url = URL(fileURLWithPath: id).appendingPathComponent("followups.md")
            let old = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            try? (old + entry).write(to: url, atomically: true, encoding: .utf8)
            s.refresh()
            if !NSApp.isActive { s.postNotification("\(s.providerName) 回答了你的追问", q, id: id) }
        }
    }

    private static func describe(_ c: [String: Any]) -> String? {
        switch c["type"] as? String {
        case "tool_use":
            let input = c["input"] as? [String: Any] ?? [:]
            let file = (input["file_path"] as? String).map { ($0 as NSString).lastPathComponent } ?? ""
            switch c["name"] as? String ?? "" {
            case "Skill": return "加载复盘规则"
            case "Read": return "阅读 \(file)"
            case "Write": return "写入 \(file)"
            case "Edit", "MultiEdit": return "更新 \(file)"
            case "Bash": return "读取 / 整理文件"
            case "Glob", "Grep": return "查找文件"
            case let n: return n
            }
        case "text":
            let t = (c["text"] as? String ?? "").split(separator: "\n").first.map(String.init) ?? ""
            return t.isEmpty ? nil : String(t.prefix(80))
        default: return nil
        }
    }

    func cancelJob(_ id: String) {
        pendingAnalyze.remove(id)
        processes[id]?.terminate()
    }

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
