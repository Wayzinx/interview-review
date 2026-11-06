import AppKit
import Foundation

/// DMG 版的运行环境：首次启动时把 App 内置的转写程序拷到 Application Support，用内置的 uv 按锁文件装好依赖。
/// 开发版（源码目录编译）不走这里，环境由 scripts/install.sh 准备。
extension Store {
    var runtimeReady: Bool {
        guard FileManager.default.isExecutableFile(atPath: pyCLI) else { return false }
        guard devRoot == nil, let src = bundledRuntime else { return true }
        // 换了新版本 App：内置程序版本变了就重新准备（依赖没变时 uv 几秒就好）
        let v = { (u: URL) in try? String(contentsOf: u.appendingPathComponent("VERSION"), encoding: .utf8) }
        return v(src) == v(runtimeRoot)
    }

    /// 需要转写程序的操作都先过这里：环境好了直接做，没好就先准备再做
    func withRuntime(_ action: @escaping () -> Void) {
        if runtimeReady { action() } else { prepareRuntime(then: action) }
    }

    func prepareRuntime(then action: (() -> Void)? = nil) {
        if let action { afterRuntime.append(action) }
        guard runtimeJob == nil else { return }
        guard devRoot == nil, let src = bundledRuntime else {
            afterRuntime.removeAll()
            alert = AppAlert(title: "转写环境没准备好", message: "这是从源码编译的版本：在源码目录运行 scripts/install.sh（或 uv sync）。")
            return
        }
        runtimeJob = Job(kind: .transcribe, line: "复制转写程序…")
        let fm = FileManager.default
        try? fm.createDirectory(at: runtimeRoot, withIntermediateDirectories: true)
        for name in ["ir", "pyproject.toml", "uv.lock", "VERSION"] {
            let dst = runtimeRoot.appendingPathComponent(name)
            try? fm.removeItem(at: dst)
            try? fm.copyItem(at: src.appendingPathComponent(name), to: dst)
        }
        var env = baseEnv()
        env["UV_PROJECT_ENVIRONMENT"] = runtimeRoot.appendingPathComponent(".venv").path
        var tail: [String] = []
        do {
            try runProcess(
                src.appendingPathComponent("uv").path,
                ["sync", "--project", runtimeRoot.path, "--frozen", "--no-dev"], env: env,
                onLine: { line in
                    let l = line.trimmingCharacters(in: .whitespaces)
                    guard !l.isEmpty else { return }
                    tail.append(l)
                    self.runtimeJob?.line = Self.describeUv(l)
                    self.runtimeJob?.steps += 1
                },
                done: { code in
                    self.runtimeJob = nil
                    self.refresh()
                    if code == 0, self.runtimeReady {
                        let todo = self.afterRuntime
                        self.afterRuntime.removeAll()
                        todo.forEach { $0() }
                    } else {
                        self.afterRuntime.removeAll()
                        self.alert = AppAlert(
                            title: "转写环境准备失败",
                            message: tail.suffix(5).joined(separator: "\n") + "\n\n多半是网络问题（需要访问 pypi.org 和 GitHub）。检查网络后在首页「准备情况」里点「重试」。")
                    }
                })
        } catch {
            runtimeJob = nil
            afterRuntime.removeAll()
            alert = AppAlert(title: "转写环境准备失败", message: error.localizedDescription)
        }
    }

    /// uv 的输出翻成人话
    static func describeUv(_ l: String) -> String {
        if l.hasPrefix("Downloading cpython") || l.contains("Installed Python") { return "下载 Python…" }
        if l.hasPrefix("Downloading ") { return "下载 " + l.dropFirst(12) }
        if l.hasPrefix("Prepared ") { return "依赖下载完成，正在安装…" }
        if l.hasPrefix("Installed ") { return "安装完成" }
        if l.hasPrefix("Creating virtual environment") { return "创建 Python 环境…" }
        return l
    }

    /// DMG 版：把内置的复盘规则装到 Claude Code（~/.claude/skills/interview-review），已有就不动
    func installBundledSkill() {
        guard devRoot == nil, let src = bundledRuntime?.appendingPathComponent("skill") else { return }
        let fm = FileManager.default
        let skills = homeDir.appendingPathComponent(".claude/skills")
        let dst = skills.appendingPathComponent("interview-review")
        if fm.fileExists(atPath: dst.path) || (try? fm.destinationOfSymbolicLink(atPath: dst.path)) != nil {
            // 自己装的旧版本：内容不同就更新（软链或用户自己改过的不动）
            if (try? fm.destinationOfSymbolicLink(atPath: dst.path)) == nil,
                let old = try? String(contentsOf: dst.appendingPathComponent("SKILL.md"), encoding: .utf8),
                let new = try? String(contentsOf: src.appendingPathComponent("SKILL.md"), encoding: .utf8),
                old != new, fm.fileExists(atPath: dst.appendingPathComponent(".installed-by-app").path)
            {
                try? new.write(to: dst.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
            }
            return
        }
        try? fm.createDirectory(at: skills, withIntermediateDirectories: true)
        try? fm.copyItem(at: src, to: dst)
        fm.createFile(atPath: dst.appendingPathComponent(".installed-by-app").path, contents: nil)
    }
}
