import AVFoundation
import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject var store: Store
    @State private var dropTargeted = false

    /// 调试截图用：macOS 26 的玻璃侧边栏截不到，IR_FLAT_SIDEBAR=1 时改成普通并排布局。
    private static let flat = ProcessInfo.processInfo.environment["IR_FLAT_SIDEBAR"] != nil

    var body: some View {
        Group {
            if Self.flat {
                HStack(spacing: 0) {
                    Sidebar().frame(width: 270)
                    Divider()
                    Detail()
                }
            } else {
                NavigationSplitView {
                    Sidebar().navigationSplitViewColumnWidth(min: 240, ideal: 270, max: 360)
                } detail: {
                    Detail()
                }
            }
        }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 14)
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [8]))
                    .background(Color.accentColor.opacity(0.06))
                    .overlay(Label("松手导入这段录音 / 录屏", systemImage: "square.and.arrow.down").font(.title2))
                    .padding(8)
                    .allowsHitTesting(false)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let u = urls.first else { return false }
            guard UTType(filenameExtension: u.pathExtension)?.conforms(to: .audiovisualContent) == true else {
                store.alert = AppAlert(title: "只能导入音频或视频", message: "「\(u.lastPathComponent)」不是录音或录屏文件。")
                return false
            }
            store.importURL(u)
            return true
        } isTargeted: { dropTargeted = $0 }
        .alert(item: $store.alert) { a in
            if let url = a.settingsURL {
                return Alert(
                    title: Text(a.title), message: Text(a.message),
                    primaryButton: .default(Text("打开系统设置")) { NSWorkspace.shared.open(url) },
                    secondaryButton: .cancel(Text("好")))
            }
            return Alert(title: Text(a.title), message: Text(a.message))
        }
        .sheet(item: $store.renaming) { s in RenameSheet(session: s) }
    }
}

// MARK: - 侧边栏

struct Sidebar: View {
    @EnvironmentObject var store: Store
    @State private var trashing: Session?
    @State private var query = ""

    private var filtered: [Session] {
        query.isEmpty ? store.sessions : store.sessions.filter { $0.title.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        List(selection: $store.route) {
            Section {
                HStack {
                    Image(systemName: store.isRecording ? "record.circle.fill" : "record.circle").foregroundStyle(.red)
                    Text(store.isRecording ? "录音中" : "新面试录音")
                    Spacer()
                    if let r = store.recording {
                        Text(clock(r.snap.elapsed)).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
                .tag(Route.record)
            }
            Section("面试记录") {
                if store.sessions.isEmpty {
                    Text("还没有面试记录").foregroundStyle(.secondary)
                } else if filtered.isEmpty {
                    Text("没有匹配「\(query)」的面试").foregroundStyle(.secondary)
                }
                ForEach(filtered) { s in
                    SessionRow(session: s)
                        .tag(Route.session(s.id))
                        .contextMenu {
                            Button("重命名…") { store.renaming = s }
                            Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([s.url]) }
                            Divider()
                            Button("移到废纸篓…", role: .destructive) { trashing = s }
                                .disabled(store.jobs[s.id] != nil || store.recording?.dir == s.url)
                        }
                }
            }
            Section("成长") {
                Label("弱项档案", systemImage: "chart.line.uptrend.xyaxis").tag(Route.bank("weaknesses"))
                Label("题库", systemImage: "list.bullet.rectangle").tag(Route.bank("questions"))
            }
        }
        .listStyle(.sidebar)
        .modifier(SidebarSearch(query: $query))
        .safeAreaInset(edge: .bottom) { SidebarFooter() }
        .confirmationDialog(
            "把「\(trashing?.title ?? "")」移到废纸篓？",
            isPresented: Binding(get: { trashing != nil }, set: { if !$0 { trashing = nil } }),
            presenting: trashing
        ) { s in
            Button("移到废纸篓", role: .destructive) { store.trash(s) }
        } message: { _ in
            Text("录音、对话稿和报告会一起移到废纸篓，可以从废纸篓恢复。")
        }
    }
}

/// 侧边栏搜索框。截图调试模式（IR_FLAT_SIDEBAR）下不放：没有分栏时它会跑到标题栏，截出来是一块白条。
private struct SidebarSearch: ViewModifier {
    @Binding var query: String
    private static let off = ProcessInfo.processInfo.environment["IR_FLAT_SIDEBAR"] != nil

    func body(content: Content) -> some View {
        if Self.off {
            content
        } else {
            content.searchable(text: $query, placement: .sidebar, prompt: "搜索面试")
        }
    }
}

struct SessionRow: View {
    let session: Session
    @EnvironmentObject var store: Store

    private static let fmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "M月d日 HH:mm"
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(session.title).fontWeight(.medium).lineLimit(1)
            HStack(spacing: 6) {
                Text(session.date.map(Self.fmt.string) ?? "").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if let job = store.jobs[session.id] {
                    ProgressView().controlSize(.mini)
                    Text(job.kind == .transcribe ? "转写中" : job.kind == .followup ? "追问中" : "复盘中")
                        .font(.caption2).foregroundStyle(.secondary)
                } else if store.recording?.dir == session.url {
                    Text("录音中").font(.caption2).foregroundStyle(.red)
                } else {
                    if let s = session.score { ScoreBadge(score: s) }
                    StatusBadge(status: session.status)
                }
            }
        }
        .padding(.vertical, 3)
    }
}

struct StatusBadge: View {
    let status: String
    var color: Color {
        switch status {
        case "已复盘": return .green
        case "已转写": return .blue
        case "仅录音", "待恢复": return .orange
        default: return .gray
        }
    }

    var body: some View {
        Text(status).font(.caption2.weight(.medium))
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }
}

struct ScoreBadge: View {
    let score: Double
    var color: Color { score < 2.5 ? .red : score < 3.5 ? .orange : .green }

    var body: some View {
        Text(String(format: "%g 分", score)).font(.caption2.weight(.semibold)).monospacedDigit()
            .foregroundStyle(color)
            .help("这场面试的整体评分（满分 5）")
    }
}

struct SidebarFooter: View {
    @EnvironmentObject var store: Store

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Divider()
            Button { store.importFile() } label: {
                Label("导入录音 / 录屏…", systemImage: "square.and.arrow.down")
            }
            .help("也可以直接把文件拖进窗口")
            Button { store.setResume() } label: {
                Label(store.resumeFile.map { "简历：\($0)" } ?? "设置简历…", systemImage: "person.text.rectangle")
                    .lineLimit(1)
            }
            .help("复盘时会参考简历，示范答法会贴合你的真实经历")
            SettingsLink { Label("设置", systemImage: "gearshape") }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 14).padding(.bottom, 12)
    }
}

// MARK: - 右侧

struct Detail: View {
    @EnvironmentObject var store: Store

    var body: some View {
        switch store.route {
        case .record?:
            RecordView()
        case .session(let id)?:
            if let s = store.session(id) {
                SessionView(session: s).id(id)
            } else {
                WelcomeView()
            }
        case .bank(let kind)?:
            BankView(kind: kind).id(kind)
        default:
            // 调试截图用：设置窗口没法用代码打开，嵌在这里看
            if ProcessInfo.processInfo.environment["IR_SHOW_SETTINGS"] != nil { SettingsView() } else { WelcomeView() }
        }
    }
}

struct WelcomeView: View {
    @EnvironmentObject var store: Store

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                Image(systemName: "waveform.and.mic").font(.system(size: 52)).foregroundStyle(.tint)
                Text("面试复盘").font(.largeTitle.bold())
                Text("录下面试 → 本地转写 → AI 逐题分析：哪里答得不好、怎么答更好")
                    .foregroundStyle(.secondary)
                HStack(spacing: 14) {
                    Button { store.route = .record } label: {
                        Label("开始录音", systemImage: "record.circle").frame(minWidth: 130)
                    }
                    .buttonStyle(.borderedProminent).tint(.red)
                    Button { store.importFile() } label: {
                        Label("导入录音 / 录屏", systemImage: "square.and.arrow.down").frame(minWidth: 130)
                    }
                }
                .controlSize(.large)
                .padding(.top, 4)
                Text("面试中不用切回来：⌃⌥⌘R 开始/结束录音，⌃⌥⌘M 标记没答好的地方")
                    .font(.callout).foregroundStyle(.secondary)

                if !store.readiness.allGood {
                    GroupBox {
                        ReadinessRows().padding(6)
                    } label: {
                        Label("开始前检查一下", systemImage: "checklist").font(.headline)
                    }
                    .frame(maxWidth: 620)
                }

                HStack(alignment: .top, spacing: 14) {
                    StepCard(n: 1, icon: "mic", title: "录音", text: "电脑播放的声音（面试官）和麦克风（你）分两条轨录，不用进会议，对方无感知")
                    StepCard(n: 2, icon: "text.bubble", title: "转写", text: "在本机做语音识别，录音不出电脑；已有的录音、录屏也能拖进来")
                    StepCard(n: 3, icon: "checklist", title: "复盘", text: "逐题分析考察点、你的问题、更好的答法和可能的追问，还能继续追问 AI")
                }
                .frame(maxWidth: 760)
                .padding(.top, 8)
            }
            .padding(40)
            .frame(maxWidth: .infinity)
        }
    }
}

/// 准备情况：权限、模型、账号、简历。首页和设置共用。
struct ReadinessRows: View {
    @EnvironmentObject var store: Store

    var body: some View {
        let r = store.readiness
        let micOK = r.mic == .authorized
        VStack(alignment: .leading, spacing: 10) {
            ReadinessRow(
                ok: r.runtime, title: "转写环境",
                detail: r.runtime ? (devRoot != nil ? "使用源码目录的 Python 环境" : "已准备好")
                    : store.runtimeJob.map { "正在准备：\($0.line)" } ?? "首次使用要下载 Python 和语音识别依赖（约 1GB，几分钟）",
                button: r.runtime || store.runtimeJob != nil ? nil : "准备", action: { store.prepareRuntime() })
            ReadinessRow(
                ok: micOK, title: "麦克风权限",
                detail: micOK ? "已授权" : r.mic == .denied ? "被拒绝了，去系统设置里打开" : "录你的回答",
                button: micOK ? nil : "授权", action: { store.requestMic() })
            ReadinessRow(
                ok: r.screen, title: "系统录音权限",
                detail: r.screen ? "已授权（录电脑播放的声音，不录屏幕）"
                    : r.systemAudio == 1 ? "被拒绝了：系统设置 → 隐私与安全性 → 录屏与系统录音 →「仅系统录音」里打开面试复盘"
                    : "录面试官的声音；点授权后系统会弹窗询问",
                button: r.screen ? nil : r.systemAudio == 1 ? "去设置" : "授权", action: { store.requestSystemAudio() })
            if !r.screen {
                HStack(spacing: 6) {
                    Text("系统设置里已经打开了，这里还是没生效？").font(.caption).foregroundStyle(.secondary)
                    Button("修复") { store.repairScreen() }.controlSize(.small)
                }
                .padding(.leading, 28)
            }
            ReadinessRow(
                ok: r.model, title: "语音识别模型",
                detail: r.model ? "已下载，本地转写" : "第一次转写时自动下载（约 1GB）", optional: true)
            ReadinessRow(
                ok: r.claude, title: "复盘模型",
                detail: r.claude ? store.modelLabel
                    : store.provider == "deepseek" ? "还没填 DeepSeek API key：设置 → 复盘模型" : "没找到 claude 命令：先安装并登录 Claude Code")
            ReadinessRow(
                ok: r.resume, title: "简历（可选）",
                detail: r.resume ? (store.resumeFile ?? "") : "设置后示范答法会贴合你的真实经历",
                button: r.resume ? nil : "设置", action: { store.setResume() }, optional: true)
        }
    }
}

struct ReadinessRow: View {
    let ok: Bool
    let title: String
    let detail: String
    var button: String? = nil
    var action: () -> Void = {}
    var optional = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: ok ? "checkmark.circle.fill" : optional ? "circle.dashed" : "exclamationmark.circle.fill")
                .foregroundStyle(ok ? Color.green : optional ? Color.secondary : Color.orange)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).fontWeight(.medium)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let button { Button(button, action: action).controlSize(.small) }
        }
    }
}

struct StepCard: View {
    let n: Int
    let icon: String
    let title: String
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("\(n). \(title)", systemImage: icon).font(.headline)
            Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }
}

/// 跨场次的弱项档案 / 题库
struct BankView: View {
    let kind: String
    @EnvironmentObject var store: Store
    @State private var text = ""

    private var url: URL { bankDir.appendingPathComponent("\(kind).md") }
    private var title: String { kind == "weaknesses" ? "弱项档案" : "题库" }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.title2.bold())
                    Text(kind == "weaknesses" ? "每次复盘后自动更新：反复出现的问题、出现次数、有没有改善" : "所有面试被问过的题，按场次和得分记录")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                if !text.isEmpty {
                    Button { NSWorkspace.shared.open(url) } label: { Label("用默认 App 打开", systemImage: "arrow.up.forward.app") }
                }
            }
            .padding(.horizontal, 20).padding(.vertical, 14)
            Divider()
            if text.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: kind == "weaknesses" ? "chart.line.uptrend.xyaxis" : "list.bullet.rectangle")
                        .font(.system(size: 40)).foregroundStyle(.tint)
                    Text("还没有内容").font(.title3.weight(.semibold))
                    Text("生成第一份复盘报告后，这里会自动建立；面试越多越有用。").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                MarkdownView(markdown: text, chat: false, baseURL: bankDir.appendingPathComponent("x"),
                             onSeek: { _ in }, onFile: openLinked)
            }
        }
        .task {
            while !Task.isCancelled {
                let t = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
                if t != text { text = t }
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
    }

    /// 题库里的"报告"链接 → 跳到对应那场面试
    private func openLinked(_ file: URL) {
        let dir = file.standardizedFileURL.deletingLastPathComponent().path
        if store.session(dir) != nil { store.route = .session(dir) } else { NSWorkspace.shared.open(file) }
    }
}
