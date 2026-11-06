import AVFoundation
import AppKit
import Foundation
import PDFKit
import UniformTypeIdentifiers
import UserNotifications

extension Store {
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
    func invocation(_ prompt: String, extra: [String]) -> (exe: String, args: [String], env: [String: String])? {
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
    func prepareDeepSeekConfig() {
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

    var missingModelMessage: String {
        provider == "deepseek"
            ? (claudeBinary() == nil ? "没找到 Claude Code（DeepSeek 模式也要用它）：先安装 https://claude.com/claude-code"
                : "还没填 DeepSeek API key：设置 → 复盘模型")
            : "没找到 claude 命令：先安装并登录 Claude Code（https://claude.com/claude-code）"
    }

    /// 401/402 这类错误 Claude Code 会重试 10 次（好几分钟），直接停掉并说人话
    func fatalAPIError(_ status: Int) -> String? {
        switch status {
        case 401, 403:
            if provider == "deepseek" { return "DeepSeek API key 无效或已失效：设置 → 复盘模型，重新填一个" }
            return account.isEmpty ? "Claude Code 认证失败：在终端运行 claude 重新登录" : "cca 账号 \(account) 认证失败（token 失效），重新登录这个账号"
        case 402: return "DeepSeek 账户余额不足，去 platform.deepseek.com 充值后再试"
        default: return nil
        }
    }

    /// 后台跑一次 Claude Code（-p），解析 stream-json 更新进度，结束回调最终回答。
    func runClaude(
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

    static func describe(_ c: [String: Any]) -> String? {
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

}
