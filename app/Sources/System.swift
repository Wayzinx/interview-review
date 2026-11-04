import AppKit
import Carbon.HIToolbox
import CoreAudio

/// 当前的声音输出设备。用外放时麦克风会录进面试官的声音，要提醒戴耳机。
enum AudioDevices {
    struct Output: Equatable {
        var name: String
        var isSpeaker: Bool
    }

    static func output() -> Output? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id) == noErr
        else { return nil }

        addr.mSelector = kAudioObjectPropertyName
        var nameRef: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let name = AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &nameRef) == noErr
            ? (nameRef?.takeRetainedValue() as String? ?? "") : ""

        addr.mSelector = kAudioDevicePropertyTransportType
        var transport: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        _ = AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &transport)

        let headphoneName = ["耳机", "Headphone", "AirPods", "Buds"].contains { name.localizedCaseInsensitiveContains($0) }
        let speakerTransport = [kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort, kAudioDeviceTransportTypeAirPlay]
            .contains(transport)
        let isSpeaker = !headphoneName && (transport == kAudioDeviceTransportTypeBuiltIn || speakerTransport)
        return Output(name: name, isSpeaker: isSpeaker)
    }
}

/// 全局快捷键（在任何 App 里都能按，不需要辅助功能权限）：
///   ⌃⌥⌘R 开始 / 结束录音    ⌃⌥⌘M 标记"这里没答好"
enum HotKeys {
    nonisolated(unsafe) private static var actions: [UInt32: () -> Void] = [:]
    nonisolated(unsafe) private static var refs: [EventHotKeyRef?] = []
    nonisolated(unsafe) private static var installed = false

    static func register(_ id: UInt32, keyCode: Int, action: @escaping () -> Void) {
        if !installed {
            installed = true
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(
                GetApplicationEventTarget(),
                { _, event, _ in
                    var hk = EventHotKeyID()
                    GetEventParameter(
                        event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                        MemoryLayout<EventHotKeyID>.size, nil, &hk)
                    let id = hk.id
                    DispatchQueue.main.async { HotKeys.actions[id]?() }
                    return noErr
                }, 1, &spec, nil, nil)
        }
        actions[id] = action
        var ref: EventHotKeyRef?
        RegisterEventHotKey(
            UInt32(keyCode), UInt32(cmdKey | optionKey | controlKey),
            EventHotKeyID(signature: OSType(0x4952_5256), id: id), GetApplicationEventTarget(), 0, &ref)
        refs.append(ref)
    }

    static func registerDefaults() {
        register(1, keyCode: kVK_ANSI_R) { Task { @MainActor in Store.shared.toggleRecording() } }
        register(2, keyCode: kVK_ANSI_M) { Task { @MainActor in Store.shared.addMarker() } }
    }
}
