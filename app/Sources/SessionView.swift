import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SessionView: View {
    let session: Session
    @EnvironmentObject var store: Store
    @StateObject private var player = AudioPlayer()
    @StateObject private var web = WebHandle()
    @State private var tab = 0  // 0 复盘报告 / 1 对话稿 / 2 追问
    @State private var report = ""
    @State private var transcript = ""
    @State private var followups = ""
    @State private var markerCount = 0
    @State private var showContext = false
    @State private var confirmTrash = false
    @State private var question = ""
    @State private var showFeishu = false

    private var job: Job? { store.jobs[session.id] }
    private var busy: Bool { job != nil }
    private var reloadKey: String {
        [session.transcriptMTime, session.reportMTime, session.followupsMTime]
            .map { "\($0?.timeIntervalSince1970 ?? 0)" }.joined(separator: "|")
    }
    private var followupCount: Int { followups.components(separatedBy: "## 🙋").count - 1 }
    private var currentText: String { [report, transcript, followups][tab] }
    private var currentURL: URL { [session.reportURL, session.transcriptURL, session.followupsURL][tab] }
    private var tabName: String { ["复盘报告", "对话稿", "追问"][tab] }

    private static let fmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy年M月d日 HH:mm"
        return f
    }()

    var body: some View {
        VStack(spacing: 0) {
            header.padding(.horizontal, 20).padding(.top, 14).padding(.bottom, 10)
            if let job {
                JobBanner(job: job) { store.cancelJob(session.id) }
                    .padding(.horizontal, 20).padding(.bottom, 10)
            }
            if let rj = store.runtimeJob {
                RuntimeBanner(job: rj).padding(.horizontal, 20).padding(.bottom, 10)
            }
            if let err = store.jobErrors[session.id] {
                ErrorBanner(text: err) { store.jobErrors[session.id] = nil }
                    .padding(.horizontal, 20).padding(.bottom, 10)
            }
            Divider()
            Picker("", selection: $tab) {
                Text("复盘报告").tag(0)
                Text("对话稿").tag(1)
                Text(followupCount > 0 ? "追问 (\(followupCount))" : "追问").tag(2)
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 300).padding(.vertical, 8)
            content
            if tab == 2 && session.hasTranscript { followupBar }
            if session.hasAudio {
                Divider()
                PlayerBar(player: player)
            }
        }
        .task(id: reloadKey) { load() }
        .task(id: session.audioFiles) { await player.load(session.audioFiles) }
        .onAppear {
            tab = session.hasReport || !session.hasTranscript ? 0 : 1
            if let t = UserDefaults.standard.object(forKey: "debugTab") as? Int { tab = t }
            if store.contextPromptFor == session.id { showContext = true }
            if ProcessInfo.processInfo.environment["IR_SHOW_FEISHU"] != nil { showFeishu = true }  // 调试截图用
        }
        .onChange(of: store.contextPromptFor) { _, v in if v == session.id { showContext = true } }
        .onChange(of: session.hasReport) { _, has in if has && tab != 2 { tab = 0 } }
        .onDisappear { player.stop() }
        .sheet(isPresented: $showFeishu) { FeishuSheet(session: session) }
        .sheet(isPresented: $showContext) {
            ContextEditor(session: session, prompted: store.pendingAnalyze.contains(session.id))
                .onAppear { store.contextSheet(opened: session.id) }
                .onDisappear { store.contextSheet(closed: session.id) }
        }
        .confirmationDialog("把「\(session.title)」移到废纸篓？", isPresented: $confirmTrash) {
            Button("移到废纸篓", role: .destructive) { store.trash(session) }
        } message: {
            Text("录音、对话稿和报告会一起移到废纸篓，可以从废纸篓恢复。")
        }
    }

    // MARK: 头部

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(session.title).font(.title2.bold()).lineLimit(1)
                    Button { store.renaming = session } label: { Image(systemName: "pencil") }
                        .buttonStyle(.borderless).foregroundStyle(.secondary).help("重命名")
                }
                HStack(spacing: 8) {
                    if let d = session.date { Text(Self.fmt.string(from: d)) }
                    if player.duration > 0 { Text("· \(clock(player.duration))") }
                    if let s = session.score { ScoreBadge(score: s) }
                    StatusBadge(status: session.status)
                    if markerCount > 0 {
                        Label("\(markerCount) 处标记", systemImage: "flag.fill").font(.caption).foregroundStyle(.orange)
                    }
                }
                .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Button { showContext = true } label: { Label("岗位信息", systemImage: "briefcase") }
                .help("填写公司、岗位、JD，复盘会更有针对性")
            Button { store.analyze(session.id) } label: {
                Label(session.hasReport ? "重新复盘" : "生成复盘", systemImage: "sparkles")
            }
            .buttonStyle(.borderedProminent)
            .disabled(busy || !session.hasTranscript)
            Menu {
                if session.hasAudio {
                    Button(session.hasTranscript ? "重新转写" : "转写") { store.transcribe(session.id) }.disabled(busy)
                }
                if session.hasAudio {
                    Button("用飞书妙记转写（更准）…") { showFeishu = true }.disabled(busy)
                }
                if session.isMixed && session.hasTranscript {
                    Button("对调说话人（面试官 ↔ 我）") { store.swapSpeakers(session.id) }.disabled(busy)
                }
                Divider()
                Button("把「\(tabName)」导出为 PDF…", action: exportPDF).disabled(currentText.isEmpty)
                Button("用默认 App 打开「\(tabName)」") { NSWorkspace.shared.open(currentURL) }.disabled(currentText.isEmpty)
                Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([session.url]) }
                Divider()
                Button("移到废纸篓…", role: .destructive) { confirmTrash = true }.disabled(busy)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .help("更多")
        }
    }

    // MARK: 内容

    @ViewBuilder private var content: some View {
        if currentText.isEmpty {
            ScrollView { placeholder.padding(40).frame(maxWidth: .infinity) }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            MarkdownView(
                markdown: currentText, chat: tab == 1,
                playhead: tab == 1 && player.isPlaying ? player.time : nil,
                handle: web, scrollToEnd: tab == 2,
                onSeek: { player.play(at: $0) })
        }
    }

    @ViewBuilder private var placeholder: some View {
        VStack(spacing: 14) {
            if !session.hasTranscript {
                Image(systemName: "waveform").font(.system(size: 40)).foregroundStyle(.tint)
                Text("还没有对话稿").font(.title3.weight(.semibold))
                Text(job?.kind == .transcribe ? "正在本地转写，完成后\(store.pendingAnalyze.contains(session.id) ? "会自动生成复盘" : "就能生成复盘")"
                     : session.needsRecovery ? "录音正在从备份恢复…" : session.hasAudio ? "先把录音转成文字" : "这个目录里没有录音")
                    .foregroundStyle(.secondary)
                if job == nil && session.hasAudio {
                    Button("开始转写") { store.transcribe(session.id) }.controlSize(.large)
                }
            } else if tab == 0 {
                Image(systemName: "sparkles").font(.system(size: 40)).foregroundStyle(.tint)
                Text("还没有复盘报告").font(.title3.weight(.semibold))
                Text("用 \(store.modelLabel) 逐题分析：考察点、你的回答、问题在哪、更好的答法、可能的追问。大约需要 2～5 分钟。")
                    .multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 440)
                Button("生成复盘") { store.analyze(session.id) }
                    .buttonStyle(.borderedProminent).controlSize(.large).disabled(busy)
                if store.resumeFile == nil {
                    Text("提示：在左下角设置简历，示范答法会更贴合你的真实经历").font(.caption).foregroundStyle(.secondary)
                }
            } else if tab == 2 {
                Image(systemName: "bubble.left.and.text.bubble.right").font(.system(size: 40)).foregroundStyle(.tint)
                Text("对复盘有疑问？直接问 \(store.providerName)").font(.title3.weight(.semibold))
                Text("\(store.providerName) 会先读这场的对话稿和报告再回答，问答会保存在这里。").foregroundStyle(.secondary)
                VStack(spacing: 8) {
                    ForEach(Store.followupSuggestions, id: \.self) { s in
                        Button { store.followUp(session.id, s) } label: {
                            Label(s, systemImage: "arrow.up.right.circle").frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .controlSize(.large)
                        .disabled(busy)
                    }
                }
                .frame(width: 540)
                .padding(.top, 6)
            }
        }
    }

    private var followupBar: some View {
        HStack(spacing: 8) {
            TextField("问 \(store.providerName)，比如：Q2 再给我一个更好的答法", text: $question, axis: .vertical)
                .textFieldStyle(.roundedBorder).lineLimit(1...4).onSubmit(send)
            Button(action: send) { Image(systemName: "paperplane.fill") }
                .buttonStyle(.borderedProminent)
                .disabled(busy || question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.horizontal, 20).padding(.vertical, 10)
    }

    private func send() {
        guard !busy else { return }
        store.followUp(session.id, question)
        question = ""
    }

    private func exportPDF() {
        let p = NSSavePanel()
        p.allowedContentTypes = [.pdf]
        p.nameFieldStringValue = "\(session.title)-\(tabName).pdf"
        guard p.runModal() == .OK, let url = p.url else { return }
        web.exportPDF(to: url)
    }

    private func load() {
        report = (try? String(contentsOf: session.reportURL, encoding: .utf8)) ?? ""
        transcript = (try? String(contentsOf: session.transcriptURL, encoding: .utf8)) ?? ""
        followups = (try? String(contentsOf: session.followupsURL, encoding: .utf8)) ?? ""
        markerCount = ((try? Data(contentsOf: session.markersURL))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [Any] })?.count ?? 0
    }
}

// MARK: - 组件

struct JobBanner: View {
    let job: Job
    let cancel: () -> Void
    @EnvironmentObject var store: Store

    private var title: String {
        switch job.kind {
        case .transcribe: return "正在本地转写" + (job.progress.map { " \(Int($0 * 100))%" } ?? "")
        case .analyze: return "\(store.providerName) 正在复盘" + (job.steps > 0 ? "（第 \(job.steps) 步）" : "")
        case .followup: return "\(store.providerName) 正在回答追问"
        case .importing: return "正在导入"
        }
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            HStack(spacing: 12) {
                if let p = job.progress {
                    ProgressView(value: p).frame(width: 160)
                } else {
                    ProgressView().controlSize(.small)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.callout.weight(.medium))
                    Text(job.line).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Text(clock(ctx.date.timeIntervalSince(job.started)))
                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                Button("取消", action: cancel).controlSize(.small)
            }
            .padding(10)
            .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        }
    }
}

/// DMG 版首次准备转写环境时的横幅
struct RuntimeBanner: View {
    let job: Job

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            HStack(spacing: 12) {
                ProgressView().controlSize(.small)
                VStack(alignment: .leading, spacing: 2) {
                    Text("首次使用：正在准备转写环境（约 1GB，几分钟），好了会自动继续").font(.callout.weight(.medium))
                    Text(job.line).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Text(clock(ctx.date.timeIntervalSince(job.started))).font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
            .padding(10)
            .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        }
    }
}

struct ErrorBanner: View {
    let text: String
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
            Text(text).font(.callout).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            Button(action: dismiss) { Image(systemName: "xmark") }.buttonStyle(.borderless)
        }
        .padding(10)
        .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct PlayerBar: View {
    @ObservedObject var player: AudioPlayer
    @State private var dragging: Double?

    var body: some View {
        HStack(spacing: 10) {
            Button { player.skip(-10) } label: { Image(systemName: "gobackward.10") }.help("后退 10 秒")
            Button { player.toggle() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").frame(width: 18)
            }
            Button { player.skip(10) } label: { Image(systemName: "goforward.10") }.help("前进 10 秒")
            Text(clock(dragging ?? player.time)).monospacedDigit().font(.caption).frame(width: 56, alignment: .trailing)
            Slider(
                value: Binding(get: { dragging ?? player.time }, set: { dragging = $0 }),
                in: 0...max(player.duration, 1),
                onEditingChanged: { editing in
                    if !editing, let d = dragging {
                        player.seek(d)
                        dragging = nil
                    }
                })
                .help("点报告或对话稿里的时间戳，可以直接跳到那一句")
            Text(clock(player.duration)).monospacedDigit().font(.caption).foregroundStyle(.secondary)
            Menu {
                ForEach([0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { r in
                    Button(String(format: "%g×", r)) { player.rate = Float(r) }
                }
            } label: {
                Text(String(format: "%g×", player.rate)).monospacedDigit()
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .help("播放速度")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 16).padding(.vertical, 8)
    }
}

struct ContextEditor: View {
    let session: Session
    var prompted = false
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(prompted ? "趁着转写，补充一下岗位信息？" : "岗位信息").font(.title3.bold())
            Text(prompted ? "填了 JD，复盘会更清楚面试官在考察什么；不填也可以，关掉就开始复盘。"
                          : "公司、岗位、轮次、JD……复盘时会据此判断面试官的考察重点。")
                .font(.callout).foregroundStyle(.secondary)
            TextEditor(text: $text)
                .font(.body).frame(minHeight: 280)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
            HStack {
                Spacer()
                Button(prompted ? "跳过" : "取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存") {
                    try? text.write(to: session.contextURL, atomically: true, encoding: .utf8)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 580)
        .onAppear {
            if let t = try? String(contentsOf: session.contextURL, encoding: .utf8) {
                text = t
            } else {
                let p = session.title.split(separator: "-").map(String.init)
                func at(_ i: Int) -> String { i < p.count ? p[i] : "" }
                text = "公司：\(at(0))\n岗位：\(at(1))\n轮次：\(at(2))\n\nJD：\n"
            }
        }
    }
}

struct RenameSheet: View {
    let session: Session
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("重命名").font(.title3.bold())
            TextField("公司-岗位-轮次，例如：某公司-后端-一面", text: $name)
                .textFieldStyle(.roundedBorder).frame(width: 380).onSubmit(save)
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存", action: save).keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .onAppear { name = session.title }
    }

    private func save() {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return }
        dismiss()
        if n != session.title { store.rename(session, to: n) }
    }
}

/// 用飞书妙记转写的三步引导：导出混音 → 在妙记里上传并导出文字记录 → 导回来
struct FeishuSheet: View {
    let session: Session
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    @State private var exported: URL?
    @State private var exporting = false
    @State private var reanalyze = true
    @State private var dropTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("用飞书妙记转写").font(.title3.bold())
            Text("妙记的识别比本地模型准，尤其是英文术语和专有名词。三步，主要时间花在等妙记转写。")
                .font(.callout).foregroundStyle(.secondary)
            Label("请用个人飞书账号。用公司账号的话，面试录音和文字会存进公司的飞书空间。", systemImage: "exclamationmark.shield")
                .font(.callout).foregroundStyle(.orange)

            step(1, "导出上传用的音频",
                 exported.map { "已导出：\($0.lastPathComponent)" } ?? "把两条音轨混成一个文件，时间轴和这里完全一致") {
                Button(exporting ? "正在导出…" : exported == nil ? "导出并在访达中显示" : "在访达中显示") {
                    if let u = exported { return NSWorkspace.shared.activateFileViewerSelecting([u]) }
                    exporting = true
                    store.feishuExport(session.id) { url in
                        exported = url
                        exporting = false
                    }
                }
                .disabled(exporting)
            }
            step(2, "在妙记里转写并导出",
                 "飞书（切到个人账号）→ 妙记 → 上传音视频，选上面的文件。转写完成后点「…」→ 导出 → 文字记录，txt、srt、Word 都可以。") {
                EmptyView()
            }
            step(3, "导入导出的文件", "选择文件，或者直接拖进这个窗口。说话人会按两条音轨自动对上。") {
                Button("选择文件…", action: pick)
            }
            Toggle("导入后重新生成复盘", isOn: $reanalyze)
            HStack {
                Text("当前的本地转写会备份为 transcript.local.md").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 580)
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 12).stroke(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [8]))
                    .padding(4).allowsHitTesting(false)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let u = urls.first else { return false }
            importFile(u)
            return true
        } isTargeted: { dropTargeted = $0 }
    }

    private func step<C: View>(_ n: Int, _ title: String, _ detail: String, @ViewBuilder action: () -> C) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(n)").font(.headline).frame(width: 24, height: 24)
                .background(Color.accentColor.opacity(0.15), in: Circle())
            VStack(alignment: .leading, spacing: 4) {
                Text(title).fontWeight(.medium)
                Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                action()
            }
        }
    }

    private func pick() {
        let p = NSOpenPanel()
        p.allowedContentTypes = ["txt", "srt", "docx", "doc"].compactMap { UTType(filenameExtension: $0) }
        p.message = "选择飞书妙记导出的文字记录"
        guard p.runModal() == .OK, let u = p.url else { return }
        importFile(u)
    }

    private func importFile(_ u: URL) {
        store.feishuImport(session.id, file: u, reanalyze: reanalyze)
        dismiss()
    }
}
