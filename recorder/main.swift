// interview-recorder — 命令行录音。用法: interview-recorder --out <目录> [--duration <秒>]
// 输出: <目录>/interviewer.m4a  <目录>/me.m4a  <目录>/meta.json

import Foundation

func log(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }

var outPath: String?
var duration: Double?
var it = CommandLine.arguments.dropFirst().makeIterator()
while let a = it.next() {
    switch a {
    case "--out": outPath = it.next()
    case "--duration": duration = it.next().flatMap(Double.init)
    case "-h", "--help":
        log("用法: interview-recorder --out <目录> [--duration <秒>]")
        exit(0)
    default:
        log("未知参数: \(a)")
        exit(2)
    }
}
guard let outPath else {
    log("缺少 --out <目录>")
    exit(2)
}

let recorder = Recorder(outDir: URL(fileURLWithPath: outPath))
var statusTimer: DispatchSourceTimer?
var warned = false

func bar(_ db: Float) -> String {
    let n = max(0, min(10, Int((db + 60) / 6)))
    return String(repeating: "■", count: n) + String(repeating: "·", count: 10 - n)
}

func printStatus() {
    let s = recorder.snapshot()
    let el = Int(s.elapsed)
    let ts = String(format: "%02d:%02d:%02d", el / 3600, el / 60 % 60, el % 60)
    let line = String(
        format: "\r● REC %@   面试官 %@ %4.0fdB   我 %@ %4.0fdB ", ts, bar(s.interviewerDB),
        max(s.interviewerDB, -99), bar(s.meDB), max(s.meDB, -99))
    FileHandle.standardError.write(line.data(using: .utf8)!)
    if el >= 8 && !warned && s.meBuffers == 0 {
        warned = true
        log("\n⚠️  8 秒内没收到麦克风数据，检查麦克风权限/输入设备")
    }
}

func finish(code: Int32) {
    statusTimer?.cancel()
    Task {
        let s = await recorder.stop()
        log("\n已保存：\(s.outDir.path)")
        log(String(format: "时长 %.0f 秒；面试官有声 %.0f 秒，我有声 %.0f 秒", s.seconds, s.interviewerVoiced, s.meVoiced))
        if s.interviewerVoiced < 5 { log("⚠️  面试官音轨几乎没声音，检查会议软件的输出是否被录到") }
        if s.meVoiced < 5 { log("⚠️  我的音轨几乎没声音，检查麦克风") }
        exit(code)
    }
}

signal(SIGINT, SIG_IGN)
signal(SIGTERM, SIG_IGN)
var signalSources: [DispatchSourceSignal] = []
for sig in [SIGINT, SIGTERM] {
    let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    src.setEventHandler { finish(code: 0) }
    src.resume()
    signalSources.append(src)
}
recorder.onInterrupted = { err in
    log("\n录制被系统中断：\(err.localizedDescription)")
    DispatchQueue.main.async { finish(code: 1) }
}

Task {
    do {
        try await recorder.start()
    } catch RecError.screenCapture(let why) {
        log("启动失败：没有屏幕与系统录音权限：系统设置 → 隐私与安全性 → 屏幕与系统录音，给当前终端 App 打开后重开终端（\(why)）")
        exit(1)
    } catch {
        log("启动失败：\(error.localizedDescription)")
        exit(1)
    }
    log("开始录音 → \(outPath)")
    log("麦克风：\(recorder.micName)    按 Ctrl-C 结束")
    let t = DispatchSource.makeTimerSource(queue: .main)
    t.schedule(deadline: .now() + 1, repeating: 1)
    t.setEventHandler { printStatus() }
    t.resume()
    statusTimer = t
    if let duration {
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { finish(code: 0) }
    }
}
dispatchMain()
