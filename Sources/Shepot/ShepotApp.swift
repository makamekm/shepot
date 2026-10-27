import SwiftUI
import AppKit

@main
enum ShepotApp {
    @MainActor static func main() {
        let app = NSApplication.shared
        #if DEBUG
        if let index = CommandLine.arguments.firstIndex(of: "--render-hud-preview"), CommandLine.arguments.count > index + 1 {
            do { try HUDPreviewRenderer.render(to: URL(fileURLWithPath: CommandLine.arguments[index + 1])) }
            catch { fputs("HUD preview failed: \(error)\n", stderr) }
            return
        }
        #endif
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
        withExtendedLifetime(delegate) {}
    }
}

final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let model = AppModel()
    private var window: NSWindow!
    private var panel: FloatingPanel!
    private var status: NSStatusItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1130, height: 870), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "Шёпот"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.minSize = NSSize(width: 960, height: 720)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.backgroundColor = NSColor(Palette.background)
        window.contentView = NSHostingView(rootView: ContentView(app: model, settings: model.settings, history: model.history))
        window.setFrameAutosaveName("ShepotMainWindow")
        window.center()
        panel = FloatingPanel(contentRect: NSRect(origin: .zero, size: RecordingHUD.panelSize), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "Шёпот — диктовка"
        panel.isOpaque = false; panel.backgroundColor = .clear
        panel.hasShadow = true; panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let hudHost = NSHostingView(rootView: RecordingHUD(app: model, recorder: model.recorder))
        // The authorizing view is smaller than the transcript. Keep a stable panel size.
        hudHost.sizingOptions = []
        panel.contentView = hudHost
        panel.setContentSize(RecordingHUD.panelSize)
        model.showHUD = { [weak self] in self?.presentHUD() }
        model.hideHUD = { [weak self] in self?.panel.orderOut(nil) }
        model.hotkey.start()
        model.startPermissionMonitoring()
        showWindow()
    }
    private func buildMenu() {
        let mainMenu = NSMenu()
        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Открыть Шёпот", action: #selector(showWindow), keyEquivalent: "0").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Завершить Шёпот", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "Правка")
        for (title, selector, key) in [("Отменить", Selector(("undo:")), "z"), ("Вырезать", #selector(NSText.cut(_:)), "x"), ("Копировать", #selector(NSText.copy(_:)), "c"), ("Вставить", #selector(NSText.paste(_:)), "v"), ("Выбрать всё", #selector(NSText.selectAll(_:)), "a")] {
            editMenu.addItem(withTitle: title, action: selector, keyEquivalent: key)
        }
        editItem.submenu = editMenu
        NSApplication.shared.mainMenu = mainMenu
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        status.button?.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Шёпот — голосовой ввод")
        let menu = NSMenu()
        menu.addItem(withTitle: "Шёпот · ⌃⌃ начать · ⌃ закончить", action: nil, keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Начать / завершить диктовку", action: #selector(toggleRecording), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Открыть Шёпот", action: #selector(showWindow), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Настройки…", action: #selector(showSettings), keyEquivalent: ",").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Завершить", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        status.menu = menu
    }
    @objc private func toggleRecording() { model.toggle() }
    @objc private func showSettings() { model.section = .settings; showWindow() }
    @objc private func showWindow() { window?.makeKeyAndOrderFront(nil); NSApplication.shared.activate(ignoringOtherApps: true); model.refreshPermissions() }
    private func presentHUD() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        if let frame = screen?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: frame.midX - panel.frame.width / 2, y: frame.minY + 64))
        }
        panel.orderFrontRegardless()
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showWindow(); return true }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) { model.cancel(); model.hotkey.stop(); model.stopPermissionMonitoring() }
}
