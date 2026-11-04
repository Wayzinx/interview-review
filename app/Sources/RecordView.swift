import SwiftUI

struct RecordView: View {
    @EnvironmentObject var store: Store
    @AppStorage("lastName") private var name = ""
    @State private var starting = false
    @FocusState private var nameFocused: Bool

    var body: some View {
        ScrollView {
            Group {
                if let r = store.recording { recording(r) } else { idle }
            }
            .padding(40)
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: 未开始

    private var idle: some View {
        VStack(spacing: 18) {
            Text("新面试录音").font(.title.bold())
            TextField("公司-岗位-轮次，例如：某公司-后端-一面", text: $name)
                .textFieldStyle(.roundedBorder).frame(width: 400).focused($nameFocused).onSubmit(start)
            HStack(spacing: 12) {
                Button(action: start) {
                    Label(starting ? "正在启动…" : "开始录音", systemImage: "record.circle.fill").frame(width: 150)
                }
                .buttonStyle(.borderedProminent).tint(.red).disabled(starting || store.soundCheck?.running == true)
                Button { Task { await store.runSoundCheck() } } label: {
                    Label("录音测试", systemImage: "waveform.badge.magnifyingglass").frame(width: 110)
                }
                .disabled(store.soundCheck?.running == true)
                .help("面试前花 6 秒确认两条轨都能录到")
            }
            .controlSize(.large)

            if let c = store.soundCheck { SoundCheckPanel(check: c).frame(width: 520) }
            if store.soundCheck == nil, let o = store.output, o.isSpeaker { SpeakerNote(output: o).frame(width: 520) }

            VStack(alignment: .leading, spacing: 8) {
                Label("不戴耳机也能录到双方；戴耳机时对话稿更干净（外放的回声会自动去掉）", systemImage: "headphones")
                Label("只录声音不录屏幕：电脑播放的声音 = 面试官，麦克风 = 你；飞书、腾讯会议、Zoom 的通话声音都能录", systemImage: "speaker.wave.2")
                Label("面试中不用切回来：⌃⌥⌘R 结束录音，⌃⌥⌘M 标记没答好的地方，菜单栏有计时", systemImage: "keyboard")
                Label("录音边录边备份，App 意外退出也能恢复", systemImage: "externaldrive.badge.checkmark")
                if !store.readiness.screen || store.readiness.mic != .authorized {
                    Label("第一次使用会请求麦克风和「系统录音」权限（只录声音，不录屏幕）", systemImage: "lock.shield")
                        .foregroundStyle(.orange)
                }
            }
            .font(.callout).foregroundStyle(.secondary)
            .padding(16)
            .frame(width: 520, alignment: .leading)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
            .padding(.top, 6)
        }
        .onAppear { if name.isEmpty { nameFocused = true } }
    }

    // MARK: 录音中

    private func recording(_ r: RecordingState) -> some View {
        VStack(spacing: 22) {
            HStack(spacing: 8) {
                Circle().fill(.red).frame(width: 10, height: 10)
                    .opacity(Int(r.snap.elapsed * 2) % 2 == 0 ? 1 : 0.25)
                Text("正在录音 · \(r.name.isEmpty ? "面试" : r.name)").font(.headline)
            }
            Text(clock(r.snap.elapsed)).font(.system(size: 60, weight: .light, design: .rounded)).monospacedDigit()
            VStack(spacing: 16) {
                LevelMeter(label: "面试官（电脑声音）", db: r.snap.interviewerDB, voiced: r.snap.interviewerVoiced, color: .purple)
                LevelMeter(label: "我（麦克风：\(r.micName)）", db: r.snap.meDB, voiced: r.snap.meVoiced, color: .blue)
            }
            .frame(width: 460)

            VStack(spacing: 6) {
                if let o = store.output, o.isSpeaker { SpeakerNote(output: o).frame(width: 460) }
                if r.snap.elapsed > 8 && r.snap.meBuffers == 0 {
                    Label("没有收到麦克风数据：检查麦克风权限或输入设备", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                } else if r.snap.micSilentFor > 3 {
                    Label("麦克风 \(Int(r.snap.micSilentFor)) 秒没有数据，正在自动重连…（检查麦克风是不是被拔掉或静音了）",
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                } else if r.snap.micRestarts > 0 {
                    Label("麦克风自动重连过 \(r.snap.micRestarts) 次（换设备或耳机切到通话模式时会这样），录音没中断",
                          systemImage: "arrow.triangle.2.circlepath")
                        .foregroundStyle(.secondary)
                }
                if r.snap.elapsed > 45 && r.snap.interviewerVoiced < 1 {
                    Label("还没录到电脑播放的声音。面试官说话时上面那条会跳动，确认会议已有声音", systemImage: "info.circle")
                        .foregroundStyle(.secondary)
                }
                if let e = r.snap.error {
                    Label(e, systemImage: "xmark.octagon.fill").foregroundStyle(.red)
                }
            }
            .font(.callout)

            HStack(spacing: 12) {
                Button { store.addMarker() } label: {
                    Label("标记此刻", systemImage: "flag.fill").frame(width: 120)
                }
                .help("觉得刚才没答好就按一下（全局快捷键 ⌃⌥⌘M），复盘时会重点分析")
                Button { Task { await store.stopRecording() } } label: {
                    Label("结束录音并转写", systemImage: "stop.circle.fill").frame(width: 170)
                }
                .buttonStyle(.borderedProminent)
            }
            .controlSize(.large)

            if !r.markers.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "flag.fill").foregroundStyle(.orange)
                    Text("已标记 \(r.markers.count) 处：" + r.markers.map { clock($0) }.joined(separator: "、"))
                        .foregroundStyle(.secondary)
                }
                .font(.callout)
            }
            Text("⌃⌥⌘M 标记 · ⌃⌥⌘R 结束 —— 在会议软件里也能按").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func start() {
        guard !starting else { return }
        starting = true
        Task {
            await store.startRecording(name: name)
            starting = false
        }
    }
}

struct LevelMeter: View {
    let label: String
    let db: Float
    let voiced: Double
    let color: Color

    var level: Double { Double(max(0, min(1, (db + 60) / 60))) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(label).font(.subheadline).lineLimit(1)
                Spacer()
                Text("有声 \(clock(voiced))").font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule().fill(color.gradient).frame(width: max(8, g.size.width * level))
                }
            }
            .frame(height: 10)
            .animation(.linear(duration: 0.12), value: level)
        }
    }
}

/// 外放时的说明（不是错误）：双方都能录到，只是麦克风会顺带录进面试官的声音
struct SpeakerNote: View {
    let output: AudioDevices.Output

    var body: some View {
        Label("现在用外放（\(output.name)）：双方都能录到。麦克风会顺带录进面试官的声音，转写时自动去掉；戴耳机对话稿会更干净。",
              systemImage: "speaker.wave.2")
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct SoundCheckPanel: View {
    let check: SoundCheck
    @EnvironmentObject var store: Store

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if check.running {
                HStack {
                    Text("正在测试…").font(.headline)
                    Spacer()
                    ProgressView(value: check.progress).frame(width: 160)
                }
                Text("会播放一声提示音（模拟面试官说话），请对着麦克风说一句「测试一二三」。")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                HStack {
                    Text(check.systemOK && check.micOK ? "测试通过，可以开始面试了" : "有问题，先处理一下")
                        .font(.headline)
                    Spacer()
                    Button("关闭") { store.soundCheck = nil }.buttonStyle(.borderless)
                }
                result(check.systemOK, "电脑声音（面试官）",
                       check.systemOK ? "能录到" : "没录到提示音：确认首页「系统录音权限」是绿勾；会议 / 通话要在这台电脑上进行")
                result(check.micOK, "麦克风（你）",
                       check.micOK ? "能录到（\(check.micName)）" : "声音太小或没录到（\(check.micName)）：检查输入设备，或靠近麦克风再试")
                if let o = store.output {
                    result(true, "声音输出", o.isSpeaker ? "外放（\(o.name)）：能录，回声会自动去掉" : o.name)
                }
            }
        }
        .padding(14)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }

    private func result(_ ok: Bool, _ title: String, _ detail: String, warnOnly: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: ok ? "checkmark.circle.fill" : warnOnly ? "exclamationmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(ok ? .green : warnOnly ? .orange : .red)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).fontWeight(.medium)
                Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
