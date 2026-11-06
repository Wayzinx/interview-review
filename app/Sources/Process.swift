import Foundation

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

func baseEnv() -> [String: String] {
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

let pyCLI = runtimeRoot.appendingPathComponent(".venv/bin/interview-py").path
