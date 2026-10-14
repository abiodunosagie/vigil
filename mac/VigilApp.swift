import AppKit
import Combine
import SwiftUI

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let watcher = SessionWatcher(settings: .shared)
    private var statusItem: NSStatusItem?
    private var panel: MenuPanel?
    private var phaseWatch: AnyCancellable?
    private var settingsWindow: NSWindow?

    /// Set once Vigil has turned on launch at login by itself, so turning it off sticks.
    private static let loginSetUpKey = "didSetUpLaunchAtLogin"

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // One Vigil at a time: a second copy just leaves.
        let me = NSRunningApplication.current
        if NSRunningApplication.runningApplications(withBundleIdentifier: AppInfo.bundleID)
            .contains(where: { $0.processIdentifier != me.processIdentifier }) {
            NSApp.terminate(nil)
            return
        }
        NSApp.setActivationPolicy(.accessory)
        setUpLaunchAtLoginOnce()
        buildStatusItem()
        watcher.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        watcher.stop()
    }

    /// The first run turns on launch at login, so the icon is always in the menu bar.
    private func setUpLaunchAtLoginOnce() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: Self.loginSetUpKey) else { return }
        // On failure the flag stays unset, so the next launch tries again.
        if (try? LoginItem.set(enabled: true)) != nil {
            defaults.set(true, forKey: Self.loginSetUpKey)
        }
    }

    // MARK: menu bar

    private func buildStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.autosaveName = "VigilStatusItem"
        item.button?.target = self
        item.button?.action = #selector(iconClicked)
        // Right click (and Control click) opens the icon's menu, like every menu bar app.
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        item.button?.imagePosition = .imageLeading
        statusItem = item
        panel = MenuPanel(watcher: watcher, openSettings: { [weak self] in self?.showSettings() })
        phaseWatch = watcher.objectWillChange.receive(on: RunLoop.main).sink { [weak self] _ in
            // objectWillChange fires before the new values land; read them on the next pass.
            DispatchQueue.main.async { self?.updateStatusItem() }
        }
        updateStatusItem()
    }

    private func updateStatusItem() {
        guard let button = statusItem?.button else { return }
        let phase = watcher.phase
        button.image = NSImage(systemSymbolName: VigilIcon.symbol(holding: watcher.isHolding, phase: phase),
                               accessibilityDescription: "Vigil")
        button.image?.isTemplate = true
        button.title = watcher.activeCount > 1 ? " \(watcher.activeCount)" : ""
        if watcher.batteryBlocked {
            button.toolTip = "Vigil: battery low, the Mac sleeps normally"
            return
        }
        switch phase {
        case .working:
            button.toolTip = "Vigil: keeping the Mac awake, Claude is on a task"
        case .finishing:
            button.toolTip = "Vigil: Claude finished, normal sleep resumes shortly"
        case .idle:
            button.toolTip = watcher.manualUntil != nil
                ? "Vigil: keeping the Mac awake on your request"
                : "Vigil: Claude is idle, the Mac sleeps normally"
        }
    }

    // MARK: settings window

    @objc private func showSettings() {
        panel?.close()
        if settingsWindow == nil {
            let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable],
                                  backing: .buffered, defer: false)
            window.title = "Vigil Settings"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: SettingsView(settings: watcher.settings))
            window.center()
            settingsWindow = window
        }
        NSApp.activate()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func togglePanel() {
        panel?.toggle(below: statusItem?.button)
    }

    @objc private func iconClicked() {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            showIconMenu()
        } else {
            togglePanel()
        }
    }

    /// The icon's own menu: open the panel, Settings, or quit.
    private func showIconMenu() {
        guard let button = statusItem?.button else { return }
        panel?.close()
        let menu = NSMenu()
        menu.addItem(withTitle: "Open Vigil", action: #selector(togglePanel), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Vigil", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        // The status button is flipped, so y past its height is just under the icon.
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
    }
}
