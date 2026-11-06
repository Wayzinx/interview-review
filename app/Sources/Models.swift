import AVFoundation
import Foundation


/// 开发版：Info.plist 的 IRRoot 指向源码目录，用源码目录里的 Python 环境
let devRoot: URL? = {
    guard let p = Bundle.main.object(forInfoDictionaryKey: "IRRoot") as? String, !p.isEmpty,
        FileManager.default.fileExists(atPath: p + "/pyproject.toml")
    else { return nil }
    return URL(fileURLWithPath: p)
}()
/// DMG 版的运行环境放在这里（IR_APP_SUPPORT 可覆盖，测试用）
let appSupportDir: URL = {
    if let p = ProcessInfo.processInfo.environment["IR_APP_SUPPORT"], !p.isEmpty { return URL(fileURLWithPath: p) }
    return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/面试复盘")
}()
/// 转写程序所在目录：开发版 = 源码目录；DMG 版 = Application Support 里首次启动时准备的运行环境
let runtimeRoot: URL = devRoot ?? appSupportDir.appendingPathComponent("runtime")
/// DMG 版 App 里内置的转写程序、复盘规则和 uv
let bundledRuntime: URL? = Bundle.main.resourceURL.map { $0.appendingPathComponent("runtime") }
    .flatMap { FileManager.default.fileExists(atPath: $0.appendingPathComponent("uv").path) ? $0 : nil }
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
    var runtime = false
    var mic: AVAuthorizationStatus = .notDetermined
    /// 系统录音（仅声音）权限：0 已授权，1 拒绝，2 未询问，nil 查不到（当作可用）
    var systemAudio: Int?
    var screen: Bool { systemAudio == nil || systemAudio == 0 }
    var model = false
    var claude = false
    var resume = false
    var allGood: Bool { runtime && mic == .authorized && screen && model && claude }
}

/// 启动子进程，按行回调 stdout+stderr（主线程），结束回调退出码。
