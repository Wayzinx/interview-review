import AppKit
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var store: Store
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Form {
            Section("复盘模型") {
                Picker("用哪个模型", selection: $store.provider) {
                    Text("Claude Code").tag("claude")
                    Text("DeepSeek（API key）").tag("deepseek")
                }
                .pickerStyle(.segmented)
                if store.provider == "claude" {
                    if !store.accounts.isEmpty {
                        Picker("账号", selection: $store.account) {
                            Text("本机 Claude Code").tag("")
                            ForEach(store.accounts, id: \.self) { Text("cca · \($0)").tag($0) }
                        }
                    }
                    Text(store.account.isEmpty
                         ? "用本机已登录的 Claude Code（订阅或 API key 都行），走你自己的额度。"
                         : "通过 cca 切换到 ~/.claude-accounts 里的账号。")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    DeepSeekKeyRow()
                    Picker("模型", selection: $store.deepseekModel) {
                        Text("deepseek-v4-pro（分析更细，推荐）").tag("deepseek-v4-pro")
                        Text("deepseek-flash（更快更省）").tag("deepseek-flash")
                    }
                    Text("国内直连，按 DeepSeek API 价格计费；key 存在 macOS 钥匙串里。").font(.caption).foregroundStyle(.secondary)
                }
                HStack(spacing: 10) {
                    Button(store.modelTest?.running == true ? "测试中…" : "测试连接") { store.testModel() }
                        .disabled(store.modelTest?.running == true)
                    if let t = store.modelTest {
                        if t.running { ProgressView().controlSize(.small) }
                        Label(t.message, systemImage: t.running ? "clock" : t.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .font(.callout).lineLimit(3)
                            .foregroundStyle(t.running ? Color.secondary : t.ok ? Color.green : Color.red)
                    }
                }
            }
            .onChange(of: store.provider) { _, _ in store.modelTest = nil }
            Section("自动化") {
                Toggle("录完 / 导入后自动生成复盘", isOn: $store.autoAnalyze)
                Toggle("录完后提示填写岗位信息（JD）", isOn: $store.askContext)
                Toggle("转写、复盘完成时发通知", isOn: $store.notify)
            }
            Section("全局快捷键（在会议软件里也能按）") {
                LabeledContent("开始 / 结束录音", value: "⌃⌥⌘R")
                LabeledContent("标记「这里没答好」", value: "⌃⌥⌘M")
            }
            Section("准备情况") {
                ReadinessRows()
                Button("录音测试…") {
                    store.route = .record
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                    Task { await store.runSoundCheck() }
                }
            }
            Section("数据") {
                LabeledContent("面试数据") {
                    Button("~/Interviews") { NSWorkspace.shared.open(dataRoot) }.buttonStyle(.link)
                }
                LabeledContent("简历") {
                    HStack {
                        Text(store.resumeFile ?? "未设置").foregroundStyle(.secondary)
                        Button(store.resumeFile == nil ? "设置…" : "更换…") { store.setResume() }
                    }
                }
                Text("录音、对话稿、报告都只存在这台电脑上；只有生成复盘 / 追问时，对话稿会发给所选模型（Claude 或 DeepSeek）。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 540, height: 640)
    }
}

/// DeepSeek API key：填写后存进钥匙串，界面上不再显示明文。
struct DeepSeekKeyRow: View {
    @EnvironmentObject var store: Store
    @State private var editing = false
    @State private var key = ""

    var body: some View {
        if store.deepseekKeySaved && !editing {
            LabeledContent("API key") {
                HStack {
                    Text("已保存在钥匙串").foregroundStyle(.secondary)
                    Button("更换") { editing = true }
                    Button("删除", role: .destructive) { store.saveDeepSeekKey("") }
                }
            }
        } else {
            LabeledContent("API key") {
                HStack {
                    SecureField("sk-…", text: $key).textFieldStyle(.roundedBorder).frame(width: 230).onSubmit(save)
                    Button("保存", action: save).disabled(key.trimmingCharacters(in: .whitespaces).count < 10)
                    if editing { Button("取消") { editing = false; key = "" } }
                }
            }
            Link("去 DeepSeek 开放平台创建 API key →", destination: URL(string: "https://platform.deepseek.com/api_keys")!)
                .font(.caption)
        }
    }

    private func save() {
        guard key.trimmingCharacters(in: .whitespaces).count >= 10 else { return }
        store.saveDeepSeekKey(key)
        key = ""
        editing = false
        store.testModel()  // 存完顺手测一下
    }
}

/// 菜单栏：面试时不用切回 App 也能看计时、标记、结束。
struct MenuBarContent: View {
    @EnvironmentObject var store: Store
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if let r = store.recording {
            Text("● 录音中 \(clock(r.snap.elapsed)) · \(r.name.isEmpty ? "面试" : r.name)")
            Button("标记此刻（没答好）    ⌃⌥⌘M") { store.addMarker() }
            if !r.markers.isEmpty { Text("已标记 \(r.markers.count) 处") }
            Button("结束录音并转写    ⌃⌥⌘R") { Task { await store.stopRecording() } }
        } else {
            Button("开始录音    ⌃⌥⌘R") { store.toggleRecording() }
            Button("录音测试…") {
                show(.record)
                Task { await store.runSoundCheck() }
            }
        }
        let running = store.jobs.compactMap { id, job -> String? in
            guard job.kind != .importing else { return nil }
            let what = job.kind == .transcribe ? "转写" + (job.progress.map { " \(Int($0 * 100))%" } ?? "")
                : job.kind == .analyze ? "复盘" : "追问"
            return "正在\(what)：\(store.title(id))"
        }
        if !running.isEmpty {
            Divider()
            ForEach(running, id: \.self) { Text($0) }
        }
        Divider()
        Button("打开面试复盘") { show(nil) }
        SettingsLink { Text("设置…") }
        Divider()
        Button("退出面试复盘") { NSApp.terminate(nil) }
    }

    private func show(_ r: Route?) {
        if let r { store.route = r }
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// 菜单栏图标：录音时显示计时。顺便把"打开主窗口"交给 Store（通知点击时用）。
struct MenuBarLabel: View {
    @EnvironmentObject var store: Store
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            if let r = store.recording {
                HStack(spacing: 3) {
                    Image(systemName: r.snap.micSilentFor > 3 ? "exclamationmark.triangle.fill" : "record.circle.fill")
                    Text(clock(r.snap.elapsed)).monospacedDigit()
                }
            } else if !store.jobs.isEmpty {
                Image(systemName: "waveform.badge.ellipsis")
            } else {
                Image(systemName: "waveform.and.mic")
            }
        }
        .onAppear { store.openMainWindow = { openWindow(id: "main") } }
    }
}
