import AppKit
import SwiftUI
import UserNotifications

@main
struct InterviewReviewApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = Store.shared

    var body: some Scene {
        Window("面试复盘", id: "main") {
            ContentView()
                .environmentObject(store)
                .frame(minWidth: 980, minHeight: 640)
        }
        .defaultLaunchBehavior(.presented)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("新面试录音") { store.route = .record }.keyboardShortcut("n")
                Button("导入录音 / 录屏…") { store.importFile() }.keyboardShortcut("o")
            }
        }
        Settings {
            SettingsView().environmentObject(store)
        }
        MenuBarExtra {
            MenuBarContent().environmentObject(store)
        } label: {
            MenuBarLabel().environmentObject(store)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private var termSource: DispatchSourceSignal?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 被 kill / 关机脚本结束时：先把录音写完整再退（默认会直接断掉，只剩备份）
        signal(SIGTERM, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        src.setEventHandler {
            Task { @MainActor in
                await Store.shared.stopRecording(transcribe: false)
                exit(0)
            }
        }
        src.resume()
        termSource = src
        HotKeys.registerDefaults()
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        DebugSnapshot.runIfRequested()
        // 保险：启动后没有主窗口就开一个
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            if !NSApp.windows.contains(where: { $0.isVisible && $0.canBecomeMain }) { Store.shared.openMainWindow?() }
        }
    }

    /// 点 Dock 图标时主窗口已关：重新打开
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { Store.shared.openMainWindow?() }
        return true
    }

    /// 关掉窗口不退出：录音、转写、复盘都还在后台，菜单栏可以找回来。
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// 录音中退出：先把两条轨写完整再退。
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard Store.shared.isRecording else { return .terminateNow }
        Task {
            await Store.shared.stopRecording(transcribe: false)
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    /// 点通知：打开对应那场面试
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let id = response.notification.request.content.userInfo["session"] as? String
        Task { @MainActor in
            let store = Store.shared
            if let id { store.route = .session(id) }
            store.openMainWindow?()
            NSApp.activate(ignoringOtherApps: true)
        }
        completionHandler()
    }
}
