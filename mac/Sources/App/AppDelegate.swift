import AppKit
import SwiftUI
import Combine

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate {
    private var mainWindow: NSWindow?
    private var statusItem: NSStatusItem?
    private var viewer: ViewerWindowController?
    private var cancellables = Set<AnyCancellable>()
    private let app = AppState.shared

    private var launchedAsLoginItem = false

    func applicationWillFinishLaunching(_ n: Notification) {
        if let e = NSAppleEventManager.shared().currentAppleEvent,
           let d = e.paramDescriptor(forKeyword: AEKeyword(keyAEPropData)) {
            launchedAsLoginItem = d.enumCodeValue == OSType(keyAELaunchedAsLogInItem)
        }
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        buildMenu()
        buildStatusItem()
        Notifier.setup()

        app.onViewerStart = { [weak self] s in self?.openViewer(s) }
        app.onViewerEnd = { [weak self] in
            self?.viewer?.close(reason: "")
            self?.viewer = nil
            self?.showMain()
            self?.updateActivationPolicy()
        }
        app.onHostStart = { [weak self] in self?.showMain() }

        // Started by the login item → stay in the menu bar only.
        let launchedAtLogin = launchedAsLoginItem
            || (app.config.launchAtLogin && ProcessInfo.processInfo.systemUptime < 180)
        if !launchedAtLogin { showMain() } else { NSApp.setActivationPolicy(.accessory) }
        app.start()

        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.app.refreshPermissions()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMain()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    // MARK: windows

    func showMain() {
        NSApp.setActivationPolicy(.regular)
        if mainWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 640),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.title = "Tether"
            w.titlebarAppearsTransparent = true
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: MainView())
            w.minSize = NSSize(width: 720, height: 520)
            w.center()
            w.setFrameAutosaveName("TetherMain")
            w.delegate = self
            mainWindow = w
        }
        mainWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        if (notification.object as? NSWindow) === mainWindow {
            DispatchQueue.main.async { self.updateActivationPolicy() }
        }
    }

    /// Show a Dock icon only while a window is open; otherwise live in the menu bar.
    private func updateActivationPolicy() {
        let anyVisible = (mainWindow?.isVisible ?? false) || viewer != nil
        NSApp.setActivationPolicy(anyVisible ? .regular : .accessory)
    }

    private func openViewer(_ s: ViewerSession) {
        viewer?.close(reason: "")
        let vc = ViewerWindowController(session: s)
        viewer = vc
        NSApp.setActivationPolicy(.regular)
        vc.showWindow(nil)
        vc.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        mainWindow?.orderOut(nil)
    }

    // MARK: menus

    private func buildMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Tether", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Tether", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Tether", action: #selector(quitApp), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)

        let winItem = NSMenuItem()
        let win = NSMenu(title: "Window")
        win.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        win.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        winItem.submenu = win
        main.addItem(winItem)
        NSApp.mainMenu = main
        NSApp.windowsMenu = win
    }

    private func buildStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let b = item.button {
            let img = NSImage(systemSymbolName: "link.circle", accessibilityDescription: "Tether")
            img?.isTemplate = true
            b.image = img
        }
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
        app.$host.receive(on: DispatchQueue.main).sink { [weak self] h in
            let name = h == nil ? "link.circle" : "link.circle.fill"
            self?.statusItem?.button?.image = NSImage(systemSymbolName: name, accessibilityDescription: "Tether")
            self?.statusItem?.button?.contentTintColor = h == nil ? nil : .systemRed
        }.store(in: &cancellables)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let id = NSMenuItem(title: "ID: \(formatID(app.config.id))", action: #selector(copyID), keyEquivalent: "")
        id.target = self
        menu.addItem(id)
        let pw = NSMenuItem(title: "Password: \(app.otp)", action: #selector(copyPassword), keyEquivalent: "")
        pw.target = self
        menu.addItem(pw)
        let st = NSMenuItem(title: app.host != nil ? "● Being controlled by \(app.host!.viewer)" : app.relayStatus, action: nil, keyEquivalent: "")
        st.isEnabled = false
        menu.addItem(st)
        if app.host != nil {
            let end = NSMenuItem(title: "End remote session", action: #selector(endHost), keyEquivalent: "")
            end.target = self
            menu.addItem(end)
        }
        menu.addItem(.separator())
        let open = NSMenuItem(title: "Open Tether", action: #selector(openMain), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        let quit = NSMenuItem(title: "Quit Tether", action: #selector(quitApp), keyEquivalent: "")
        quit.target = self
        menu.addItem(quit)
    }

    @objc private func copyID() { copyToPasteboard(app.config.id) }
    @objc private func copyPassword() { copyToPasteboard(app.otp) }
    @objc private func endHost() { app.endHostSession() }
    @objc private func openMain() { showMain() }
    @objc private func quitApp() { app.quit() }
}
