import AVFoundation
import AppKit
import Foundation
import PDFKit
import UniformTypeIdentifiers
import UserNotifications

extension Store {
    // MARK: 导入

    func importFile() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.audiovisualContent]
        p.message = "选择面试录音或录屏（两个人的声音在同一个文件里也可以）"
        guard p.runModal() == .OK, let file = p.url else { return }
        importURL(file)
    }

    func importURL(_ file: URL) {
        guard runtimeReady else { return prepareRuntime { self.importURL(file) } }
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

    // MARK: 转写

    func transcribe(_ id: String) {
        guard runtimeReady else { return prepareRuntime { self.transcribe(id) } }
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
    func startPendingAnalyze(_ id: String) {
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
        guard runtimeReady else { return prepareRuntime { self.swapSpeakers(id) } }
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

    // MARK: 飞书妙记

    /// 生成给妙记上传的混音文件，并在访达里选中它
    func feishuExport(_ id: String, done: @escaping (URL?) -> Void) {
        guard runtimeReady else { return prepareRuntime { self.feishuExport(id, done: done) } }
        var out: [String] = []
        do {
            try runProcess(
                pyCLI, ["feishu-export", id], env: baseEnv(), onLine: { out.append($0) },
                done: { code in
                    if code == 0, let path = out.last(where: { $0.hasPrefix("/") }) {
                        let url = URL(fileURLWithPath: path)
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                        done(url)
                    } else {
                        self.alert = AppAlert(title: "导出失败", message: out.suffix(4).joined(separator: "\n"))
                        done(nil)
                    }
                })
        } catch {
            alert = AppAlert(title: "导出失败", message: error.localizedDescription)
            done(nil)
        }
    }

    /// 用妙记导出的文字记录替换本地转写（本地版本备份为 transcript.local.*）
    func feishuImport(_ id: String, file: URL, reanalyze: Bool) {
        guard runtimeReady else { return prepareRuntime { self.feishuImport(id, file: file, reanalyze: reanalyze) } }
        guard jobs[id] == nil else { return }
        jobErrors[id] = nil
        jobs[id] = Job(kind: .transcribe, line: "导入飞书妙记文字记录…")
        var tail: [String] = []
        do {
            processes[id] = try runProcess(
                pyCLI, ["feishu-import", id, file.path], env: baseEnv(),
                onLine: { line in
                    if !line.isEmpty, !line.contains("torchaudio"), !line.contains("ffmpeg") { tail.append(line) }
                },
                done: { code in
                    self.jobs[id] = nil
                    self.processes[id] = nil
                    self.refresh()
                    guard code == 0 else {
                        let why = tail.last(where: { $0.contains("Error") || $0.contains("没从") }) ?? tail.suffix(3).joined(separator: "\n")
                        self.jobErrors[id] = "导入妙记失败：\n" + why
                        return
                    }
                    if reanalyze { self.analyze(id) }
                })
        } catch {
            jobs[id] = nil
            jobErrors[id] = "导入妙记失败：\(error.localizedDescription)"
        }
    }
}
