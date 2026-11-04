// 录音核心，命令行（main.swift）和 App 共用。
// 系统声音 = 面试官，麦克风 = 我。两条轨按同一个起点 t0 对齐，断流处补静音，转写后的时间戳可以直接合并。

@preconcurrency import AVFoundation
import AudioToolbox
import CoreAudio
import CoreMedia
import Foundation
import ScreenCaptureKit

let kSampleRate: Double = 16000
let kVoicedDB: Float = -45

/// 每条轨写两份：m4a（正常结束才完整）+ partial.wav（边录边落盘，App 崩溃/断电也能恢复）。
/// 正常结束后删掉 partial.wav；启动时发现残留的 partial.wav 就用 RecordingRecovery 修复。
final class TrackWriter {
    let label: String
    let url: URL
    var partialURL: URL { url.deletingPathExtension().appendingPathExtension("partial.wav") }
    private var file: AVAudioFile?
    private var partial: FileHandle?
    private var lastSync = Date()
    private var converter: AVAudioConverter?
    private var inFormat: AVAudioFormat?
    private let outFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: kSampleRate, channels: 1, interleaved: false)!
    private(set) var written: Int64 = 0
    private(set) var voiced: Int64 = 0
    private(set) var buffers = 0
    private(set) var writeError: String?
    var levelDB: Float = -160

    init(label: String, url: URL) {
        self.label = label
        self.url = url
    }

    func open() throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: kSampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 32000,
        ]
        file = try AVAudioFile(
            forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        FileManager.default.createFile(atPath: partialURL.path, contents: wavHeader(dataBytes: 0))
        partial = try FileHandle(forWritingTo: partialURL)
        _ = try? partial?.seekToEnd()
    }

    func close() {
        file?.close()
        file = nil
        try? partial?.close()
        partial = nil
        try? FileManager.default.removeItem(at: partialURL)
    }

    var seconds: Double { Double(written) / kSampleRate }
    var voicedSeconds: Double { Double(voiced) / kSampleRate }

    func append(_ sb: CMSampleBuffer, t0: Double) {
        guard let fd = CMSampleBufferGetFormatDescription(sb),
            let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(fd)
        else { return }
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sb))
        var asbd = asbdPtr.pointee
        guard frames > 0, let fmt = AVAudioFormat(streamDescription: &asbd),
            let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames)
        else { return }
        buf.frameLength = frames
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sb, at: 0, frameCount: Int32(frames), into: buf.mutableAudioBufferList) == noErr
        else { return }
        append(buf, pts: CMSampleBufferGetPresentationTimeStamp(sb).seconds, t0: t0)
    }

    /// pts / t0：主机时钟秒数。两条轨用同一个时钟，才能对齐。
    func append(_ inBuf: AVAudioPCMBuffer, pts: Double, t0: Double) {
        let frames = inBuf.frameLength
        if frames == 0 { return }
        if inFormat == nil || inFormat! != inBuf.format {
            inFormat = inBuf.format
            converter = AVAudioConverter(from: inBuf.format, to: outFormat)
            converter?.downmix = true
        }
        guard let inFormat, let converter else { return }

        let cap = AVAudioFrameCount(Double(frames) * kSampleRate / inFormat.sampleRate) + 256
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: cap) else { return }
        var fed = false
        var err: NSError?
        converter.convert(to: outBuf, error: &err) { _, status in
            if fed {
                status.pointee = .noDataNow
                return nil
            }
            fed = true
            status.pointee = .haveData
            return inBuf
        }
        if err != nil || outBuf.frameLength == 0 { return }

        // 对齐：这块数据应该落在 t0 之后的第 expected 个采样；落后超过 0.2s 说明中间断流了，补静音。
        let expected = Int64((pts - t0) * kSampleRate)
        if expected - written > Int64(kSampleRate * 0.2) { padSilence(expected - written) }

        let n = Int(outBuf.frameLength)
        let p = outBuf.floatChannelData![0]
        var sum: Float = 0
        for i in 0..<n { sum += p[i] * p[i] }
        levelDB = 10 * log10(max(sum / Float(n), 1e-16))
        if levelDB > kVoicedDB { voiced += Int64(n) }
        write(outBuf)
        buffers += 1
    }

    private func padSilence(_ count: Int64) {
        var left = count
        while left > 0 {
            let n = AVAudioFrameCount(min(left, Int64(kSampleRate)))
            guard let b = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: n) else { return }
            b.frameLength = n  // 新分配的 buffer 内容是 0
            write(b)
            left -= Int64(n)
        }
    }

    private func write(_ b: AVAudioPCMBuffer) {
        do {
            try file?.write(from: b)
            written += Int64(b.frameLength)
        } catch {
            writeError = "写入\(label)音轨失败：\(error.localizedDescription)"
        }
        // 备份：16-bit PCM 直接追加，每 5 秒刷一次盘
        let n = Int(b.frameLength)
        let p = b.floatChannelData![0]
        var pcm = [Int16](repeating: 0, count: n)
        for i in 0..<n { pcm[i] = Int16(max(-1, min(1, p[i])) * 32767) }
        pcm.withUnsafeBytes { try? partial?.write(contentsOf: Data($0)) }
        if Date().timeIntervalSince(lastSync) > 5 {
            try? partial?.synchronize()
            lastSync = Date()
        }
    }
}

/// 16kHz / 16-bit / 单声道 WAV 头。
func wavHeader(dataBytes: UInt32) -> Data {
    var d = Data()
    func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
    func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
    d.append(contentsOf: Array("RIFF".utf8)); u32(36 + dataBytes); d.append(contentsOf: Array("WAVE".utf8))
    d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1); u32(UInt32(kSampleRate)); u32(UInt32(kSampleRate) * 2)
    u16(2); u16(16)
    d.append(contentsOf: Array("data".utf8)); u32(dataBytes)
    return d
}

enum RecordingRecovery {
    /// 目录里有没正常结束的录音吗（残留 partial.wav，且 20 秒没再更新——还在更新说明正在录）。
    static func needsRecovery(_ dir: URL) -> Bool {
        let fm = FileManager.default
        return ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).contains { name in
            guard name.hasSuffix(".partial.wav"),
                let m = (try? fm.attributesOfItem(atPath: dir.appendingPathComponent(name).path))?[.modificationDate] as? Date
            else { return false }
            return Date().timeIntervalSince(m) > 20
        }
    }

    /// 修好 WAV 头、转成 m4a 覆盖坏掉的文件、补 meta.json。返回恢复出的录音时长（秒）。
    @discardableResult
    static func recover(_ dir: URL) -> Double {
        let fm = FileManager.default
        var longest = 0.0
        var tracks: [String: Any] = [:]
        for name in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] where name.hasSuffix(".partial.wav") {
            let wav = dir.appendingPathComponent(name)
            let base = String(name.dropLast(".partial.wav".count))
            let m4a = dir.appendingPathComponent(base + ".m4a")
            guard let size = (try? fm.attributesOfItem(atPath: wav.path))?[.size] as? UInt64, size > 44,
                let h = try? FileHandle(forUpdating: wav)
            else {
                try? fm.removeItem(at: wav)
                continue
            }
            let dataBytes = UInt32(min(size - 44, UInt64(UInt32.max - 36))) & ~1
            try? h.seek(toOffset: 0)
            try? h.write(contentsOf: wavHeader(dataBytes: dataBytes))
            try? h.close()
            let tmp = dir.appendingPathComponent(base + ".recovered.m4a")
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
            p.arguments = ["-f", "m4af", "-d", "aac@16000", "-b", "32000", wav.path, tmp.path]
            try? p.run()
            p.waitUntilExit()
            if p.terminationStatus == 0 {
                try? fm.removeItem(at: m4a)
                try? fm.moveItem(at: tmp, to: m4a)
                try? fm.removeItem(at: wav)
                let secs = Double(dataBytes) / 2 / kSampleRate
                longest = max(longest, secs)
                tracks[base] = ["file": base + ".m4a", "seconds": secs, "recovered": true]
            }
        }
        let meta = dir.appendingPathComponent("meta.json")
        if !fm.fileExists(atPath: meta.path), !tracks.isEmpty,
            let d = try? JSONSerialization.data(withJSONObject: ["tracks": tracks, "recovered": true], options: [.prettyPrinted])
        {
            try? d.write(to: meta)
        }
        return longest
    }
}


struct RecSnapshot {
    var elapsed: Double = 0
    var interviewerDB: Float = -160
    var meDB: Float = -160
    var interviewerVoiced: Double = 0
    var meVoiced: Double = 0
    var interviewerBuffers = 0
    var meBuffers = 0
    var error: String?
    /// 麦克风多久没来数据了（秒）；> 3 说明断流，正在重连
    var micSilentFor: Double = 0
    var micRestarts = 0
}

struct RecSummary {
    var outDir: URL
    var seconds: Double
    var interviewerVoiced: Double
    var meVoiced: Double
}

enum RecError: LocalizedError {
    case microphone
    case systemAudioDenied
    case systemAudio(String)
    case screenCapture(String)
    case noDisplay

    var errorDescription: String? {
        switch self {
        case .microphone: return "没有麦克风权限"
        case .systemAudioDenied: return "没有「系统录音」权限"
        case .systemAudio(let why): return "没法录电脑播放的声音（\(why)）"
        case .screenCapture(let why): return "没有「屏幕与系统录音」权限（\(why)）"
        case .noDisplay: return "找不到显示器"
        }
    }
}

/// "仅系统录音"权限（kTCCServiceAudioCapture）。系统没开放查询接口，这里用 TCC 私有接口查询 / 申请，拿不到时返回 nil。
enum AudioCapturePermission {
    private static let tcc = dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW)
    private static let service = "kTCCServiceAudioCapture" as CFString

    /// 0 已授权，1 已拒绝，2 还没问过
    static func status() -> Int? {
        guard let tcc, let sym = dlsym(tcc, "TCCAccessPreflight") else { return nil }
        typealias F = @convention(c) (CFString, CFDictionary?) -> Int
        return unsafeBitCast(sym, to: F.self)(service, nil)
    }

    static func request() async -> Bool {
        guard let tcc, let sym = dlsym(tcc, "TCCAccessRequest") else { return true }
        typealias F = @convention(c) (CFString, CFDictionary?, @convention(block) @escaping (Bool) -> Void) -> Void
        let f = unsafeBitCast(sym, to: F.self)
        return await withCheckedContinuation { c in f(service, nil) { c.resume(returning: $0) } }
    }
}

// MARK: - Core Audio 小工具

private func sysProp<T>(_ obj: AudioObjectID, _ selector: AudioObjectPropertySelector, _ value: inout T) -> OSStatus {
    var addr = AudioObjectPropertyAddress(
        mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var size = UInt32(MemoryLayout<T>.size)
    return withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, $0) }
}

private func defaultOutputDevice() -> AudioObjectID? {
    var id = AudioObjectID(kAudioObjectUnknown)
    guard sysProp(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, &id) == noErr,
        id != kAudioObjectUnknown
    else { return nil }
    return id
}

private func deviceString(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
    var ref: Unmanaged<CFString>?
    guard sysProp(id, selector, &ref) == noErr, let s = ref?.takeRetainedValue() else { return nil }
    return s as String
}

private func processObject(_ pid: pid_t) -> AudioObjectID? {
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject, mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var p = pid
    var obj = AudioObjectID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    let st = AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject), &addr, UInt32(MemoryLayout<pid_t>.size), &p, &size, &obj)
    return st == noErr && obj != kAudioObjectUnknown ? obj : nil
}

/// 系统声音：Core Audio 全局音频捕获（macOS 14.2+，"仅系统录音"权限）。
/// 截取所有程序送往扬声器 / 耳机的声音——包括开了回声消除的通话软件（飞书、腾讯会议、Zoom 的通话声音），
/// 本 App 自己的提示音除外。默认输出设备变了（连上 / 断开耳机）会自动重建。
final class SystemAudioTap {
    typealias Handler = (AVAudioPCMBuffer, Double) -> Void
    private let ioQueue = DispatchQueue(label: "system-audio-io", qos: .userInteractive)
    private let ctlQueue = DispatchQueue(label: "system-audio-ctl")
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var handler: Handler?
    private var listener: AudioObjectPropertyListenerBlock?
    private var listenAddr = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    private(set) var deviceName = ""
    private(set) var lastError: String?

    func start(_ handler: @escaping Handler) throws {
        self.handler = handler
        try ctlQueue.sync { try build() }
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            self.teardown()
            do { try self.build(); self.lastError = nil } catch { self.lastError = "切换输出设备后没能继续录系统声音" }
        }
        listener = block
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &listenAddr, ctlQueue, block)
    }

    func stop() {
        ctlQueue.sync {
            if let l = listener {
                AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &listenAddr, ctlQueue, l)
                listener = nil
            }
            teardown()
        }
        handler = nil
    }

    private func build() throws {
        let exclude = processObject(getpid()).map { [$0] } ?? []
        let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: exclude)
        desc.uuid = UUID()
        desc.name = "面试复盘"
        desc.isPrivate = true
        desc.muteBehavior = .unmuted
        var tap = AudioObjectID(kAudioObjectUnknown)
        var st = AudioHardwareCreateProcessTap(desc, &tap)
        guard st == noErr else { throw RecError.systemAudio("创建音频捕获失败 \(st)") }
        tapID = tap

        var asbd = AudioStreamBasicDescription()
        st = sysProp(tap, kAudioTapPropertyFormat, &asbd)
        guard st == noErr, let fmt = AVAudioFormat(streamDescription: &asbd) else {
            teardown()
            throw RecError.systemAudio("读取音频格式失败 \(st)")
        }
        guard let out = defaultOutputDevice(), let outUID = deviceString(out, kAudioDevicePropertyDeviceUID) else {
            teardown()
            throw RecError.systemAudio("找不到声音输出设备")
        }
        deviceName = deviceString(out, kAudioObjectPropertyName) ?? ""

        let agg: [String: Any] = [
            kAudioAggregateDeviceNameKey: "面试复盘-系统声音",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outUID]],
            kAudioAggregateDeviceTapListKey: [
                [kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: desc.uuid.uuidString]
            ],
        ]
        var aggDev = AudioObjectID(kAudioObjectUnknown)
        st = AudioHardwareCreateAggregateDevice(agg as CFDictionary, &aggDev)
        guard st == noErr else {
            teardown()
            throw RecError.systemAudio("创建聚合设备失败 \(st)")
        }
        aggID = aggDev

        var pid: AudioDeviceIOProcID?
        st = AudioDeviceCreateIOProcIDWithBlock(&pid, aggDev, ioQueue) { [weak self] _, inData, inTime, _, _ in
            guard let h = self?.handler,
                let src = AVAudioPCMBuffer(pcmFormat: fmt, bufferListNoCopy: inData, deallocator: nil),
                src.frameLength > 0, let copy = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: src.frameLength)
            else { return }
            // 回调结束后 inData 就失效了，先拷一份
            copy.frameLength = src.frameLength
            let s = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: src.audioBufferList))
            let d = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
            for i in 0..<min(s.count, d.count) {
                if let sp = s[i].mData, let dp = d[i].mData { memcpy(dp, sp, Int(min(s[i].mDataByteSize, d[i].mDataByteSize))) }
            }
            let t = inTime.pointee
            let host = t.mFlags.contains(.hostTimeValid) ? t.mHostTime : mach_absolute_time()
            h(copy, Double(AudioConvertHostTimeToNanos(host)) / 1e9)
        }
        guard st == noErr, let pid else {
            teardown()
            throw RecError.systemAudio("创建回调失败 \(st)")
        }
        procID = pid
        st = AudioDeviceStart(aggDev, pid)
        guard st == noErr else {
            teardown()
            throw RecError.systemAudio("启动失败 \(st)")
        }
    }

    private func teardown() {
        if aggID != kAudioObjectUnknown {
            if let p = procID {
                AudioDeviceStop(aggID, p)
                AudioDeviceDestroyIOProcID(aggID, p)
            }
            AudioHardwareDestroyAggregateDevice(aggID)
        }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        aggID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
        procID = nil
    }
}

/// 所有可变状态都在 queue / micQueue 上串行访问，所以标成 @unchecked Sendable。
final class Recorder: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, SCStreamOutput, SCStreamDelegate,
    @unchecked Sendable
{
    let outDir: URL
    private let queue = DispatchQueue(label: "recorder")
    private let interviewer: TrackWriter
    private let me: TrackWriter
    private var tap: SystemAudioTap?
    private var stream: SCStream?  // 兜底：Core Audio 捕获起不来时用 ScreenCaptureKit
    private var session: AVCaptureSession?
    // 麦克风自愈：耳机切通话模式 / 插拔设备时 AVCaptureSession 会静默停掉，这里盯着它
    private let micQueue = DispatchQueue(label: "mic-control")
    private var lastMicArrival = Date()
    private var lastRebuild = Date.distantPast
    private var micRestarts = 0
    private var watchdog: DispatchSourceTimer?
    private var inputListener: AudioObjectPropertyListenerBlock?
    private var inputAddr = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice, mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    private var t0: Double?
    private var firstSystem: Double?
    private var firstMic: Double?
    private var stopped = false
    private(set) var startedAt = Date()
    private(set) var micName = ""
    private(set) var systemSource = ""
    private(set) var outputName = ""
    /// 系统中途掐断录制（比如权限被撤销）时回调，调用方随后应调用 stop() 收尾。
    var onInterrupted: ((Error) -> Void)?

    init(outDir: URL) {
        self.outDir = outDir
        interviewer = TrackWriter(label: "面试官", url: outDir.appendingPathComponent("interviewer.m4a"))
        me = TrackWriter(label: "我", url: outDir.appendingPathComponent("me.m4a"))
    }

    func start() async throws {
        guard await AVCaptureDevice.requestAccess(for: .audio) else { throw RecError.microphone }
        let forceSCK = ProcessInfo.processInfo.environment["IR_FORCE_SCK"] != nil
        switch forceSCK ? nil : AudioCapturePermission.status() {
        case 1?: throw RecError.systemAudioDenied
        case 2?: if !(await AudioCapturePermission.request()) { throw RecError.systemAudioDenied }
        default: break
        }

        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        try interviewer.open()
        try me.open()

        do {
            if forceSCK { throw RecError.systemAudio("强制使用 ScreenCaptureKit") }
            let t = SystemAudioTap()
            try t.start { [weak self] buf, host in self?.queue.async { self?.gotSystem(buf, host) } }
            tap = t
            systemSource = "Core Audio"
            outputName = t.deviceName
        } catch {
            try await startScreenCapture()
            systemSource = "ScreenCaptureKit"
        }
        try micQueue.sync { try startMic() }
        startedAt = Date()
        queue.sync { lastMicArrival = Date() }
        startMicWatchdog()
    }

    /// 超过 2.5 秒没收到麦克风数据就重建；系统默认麦克风变了也重建（跟着用户换的设备走）
    private func startMicWatchdog() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 1, repeating: 1)
        t.setEventHandler { [weak self] in
            guard let self, !self.stopped else { return }
            let now = Date()
            if now.timeIntervalSince(self.lastMicArrival) > 2.5, now.timeIntervalSince(self.lastRebuild) > 3 {
                self.lastRebuild = now
                self.micQueue.async { self.rebuildMic() }
            }
        }
        t.resume()
        watchdog = t
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.rebuildMic() }
        inputListener = block
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &inputAddr, micQueue, block)
    }

    /// 在 micQueue 上调用
    private func rebuildMic() {
        guard queue.sync(execute: { !stopped }) else { return }
        session?.stopRunning()
        session = nil
        do {
            try startMic()
            queue.sync {
                micRestarts += 1
                lastMicArrival = Date()  // 给新 session 一点启动时间
            }
        } catch {
            // 设备暂时不可用，看门狗下一轮再试
        }
    }

    private func startMic() throws {
        guard let dev = AVCaptureDevice.default(for: .audio) else { throw RecError.microphone }
        let s = AVCaptureSession()
        let input = try AVCaptureDeviceInput(device: dev)
        let out = AVCaptureAudioDataOutput()
        guard s.canAddInput(input), s.canAddOutput(out) else { throw RecError.microphone }
        s.addInput(input)
        out.setSampleBufferDelegate(self, queue: queue)
        s.addOutput(out)
        s.startRunning()
        session = s
        micName = dev.localizedName
    }

    private func startScreenCapture() async throws {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            throw RecError.screenCapture(error.localizedDescription)
        }
        guard let display = content.displays.first else { throw RecError.noDisplay }
        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let cfg = SCStreamConfiguration()
        cfg.capturesAudio = true
        cfg.excludesCurrentProcessAudio = true
        cfg.sampleRate = 48000
        cfg.channelCount = 1
        cfg.width = 2
        cfg.height = 2
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        let s = SCStream(filter: filter, configuration: cfg, delegate: self)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        try await s.startCapture()
        stream = s
    }

    private func gotSystem(_ buf: AVAudioPCMBuffer, _ host: Double) {
        guard !stopped else { return }
        if t0 == nil { t0 = host }
        if firstSystem == nil { firstSystem = host }
        interviewer.append(buf, pts: host, t0: t0!)
    }

    // 麦克风（AVCaptureSession）
    func captureOutput(_ output: AVCaptureOutput, didOutput sb: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard !stopped, sb.isValid else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sb).seconds
        lastMicArrival = Date()
        if t0 == nil { t0 = pts }
        if firstMic == nil { firstMic = pts }
        me.append(sb, t0: t0!)
    }

    // 兜底的 ScreenCaptureKit 系统声音
    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard !stopped, sb.isValid, type == .audio else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sb).seconds
        if t0 == nil { t0 = pts }
        interviewer.append(sb, t0: t0!)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onInterrupted?(error)
    }

    func snapshot() -> RecSnapshot {
        queue.sync {
            RecSnapshot(
                elapsed: Date().timeIntervalSince(startedAt),
                interviewerDB: interviewer.levelDB, meDB: me.levelDB,
                interviewerVoiced: interviewer.voicedSeconds, meVoiced: me.voicedSeconds,
                interviewerBuffers: interviewer.buffers, meBuffers: me.buffers,
                error: interviewer.writeError ?? me.writeError ?? tap?.lastError,
                micSilentFor: Date().timeIntervalSince(lastMicArrival), micRestarts: micRestarts)
        }
    }

    /// 停止并把两条轨写完整、写 meta.json。可以重复调用。
    func stop() async -> RecSummary {
        watchdog?.cancel()
        watchdog = nil
        micQueue.sync {
            if let l = inputListener {
                AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &inputAddr, micQueue, l)
                inputListener = nil
            }
        }
        tap?.stop()
        tap = nil
        if let s = stream {
            stream = nil
            try? await s.stopCapture()
        }
        micQueue.sync {
            session?.stopRunning()
            session = nil
        }
        return queue.sync {
            if !stopped {
                stopped = true
                interviewer.close()
                me.close()
                writeMeta()
            }
            return RecSummary(
                outDir: outDir, seconds: max(interviewer.seconds, me.seconds),
                interviewerVoiced: interviewer.voicedSeconds, meVoiced: me.voicedSeconds)
        }
    }

    private func writeMeta() {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        iso.timeZone = .current
        let meta: [String: Any] = [
            "started_at": iso.string(from: startedAt),
            "sample_rate": kSampleRate,
            "mic_device": micName,
            "system_source": systemSource,
            "output_device": outputName,
            "mic_restarts": micRestarts,
            // 两条轨第一个数据包相对起点的秒数：都应该在 1 秒以内，否则说明时钟没对齐
            "first_packet_offset": [
                "interviewer": firstSystem.map { $0 - (t0 ?? $0) } ?? -1,
                "me": firstMic.map { $0 - (t0 ?? $0) } ?? -1,
            ],
            "tracks": [
                "interviewer": [
                    "file": "interviewer.m4a", "seconds": interviewer.seconds,
                    "voiced_seconds": interviewer.voicedSeconds,
                ],
                "me": ["file": "me.m4a", "seconds": me.seconds, "voiced_seconds": me.voicedSeconds],
            ],
        ]
        if let d = try? JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted, .sortedKeys]) {
            try? d.write(to: outDir.appendingPathComponent("meta.json"))
        }
    }
}
