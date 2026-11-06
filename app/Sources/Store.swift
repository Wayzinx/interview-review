import AVFoundation
import AppKit
import Foundation
import PDFKit
import UniformTypeIdentifiers
import UserNotifications

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
    @Published var deepseekKeySaved = Keychain.read() != nil
    @Published var modelTest: ModelTest?
    @Published var autoAnalyze: Bool { didSet { defaults.set(autoAnalyze, forKey: "autoAnalyze") } }
    @Published var askContext: Bool { didSet { defaults.set(askContext, forKey: "askContext") } }
    @Published var notify: Bool { didSet { defaults.set(notify, forKey: "notify") } }
    let accounts: [String]

    var isRecording: Bool { recording != nil }

    let defaults = UserDefaults.standard
    var recorder: Recorder?
    var processes: [String: Process] = [:]
    /// 转写完要自动复盘的会话
    @Published var pendingAnalyze: Set<String> = []
    /// 正在显示"岗位信息"弹窗的会话：等它关掉再开始自动复盘
    var contextSheetOpen: String?
    var pollTimer: Timer?
    var meterTimer: Timer?
    var micAlerted = false
    var activity: NSObjectProtocol?
    var scoreCache: [String: (Date, Double?)] = [:]

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
    func score(_ report: URL, _ mtime: Date?) -> Double? {
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

    func updateActivity() {
        let busy = recording != nil || !jobs.isEmpty
        if busy, activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(
                options: [.idleSystemSleepDisabled, .suddenTerminationDisabled], reason: "面试录音 / 转写 / 复盘进行中")
        } else if !busy, let a = activity {
            ProcessInfo.processInfo.endActivity(a)
            activity = nil
        }
    }

    func recordingChanged(_ old: RecordingState?) {
        if (old == nil) != (recording == nil) {
            NSApp.dockTile.badgeLabel = recording == nil ? nil : "REC"
            updateActivity()
        }
    }

}
