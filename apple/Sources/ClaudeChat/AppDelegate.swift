import AppKit
import ChatKit
import ChatKitUI

// MARK: - AppDelegate

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {

    private let appVM: AppViewModel
    private let appSettings: AppSettings

    /// The single main window. Held so we can hide/show it (WeChat-style: the
    /// red close button hides the window instead of quitting the app).
    private weak var mainWindow: NSWindow?

    // MARK: - Status item

    var statusItem: NSStatusItem?
    /// Right-click menu for the status item, popped up manually so left-click can
    /// stay free for "show window".
    private var statusMenu: NSMenu?
    private var unreadPollTimer: Timer?

    init(appVM: AppViewModel, appSettings: AppSettings) {
        self.appVM = appVM
        self.appSettings = appSettings
        super.init()
    }

    /// Called from main.swift right after the window is built so we can act as
    /// its delegate and intercept the close button.
    func registerMainWindow(_ window: NSWindow) {
        mainWindow = window
        window.delegate = self
    }

    // MARK: - NSApplicationDelegate

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Activation policy and foreground activation (moved from main.swift).
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        // Dock icon: the packaged .app gets it natively from AppIcon.icns
        // (CFBundleIconFile). Under `swift run` there's no bundle icon slot, but
        // we deliberately avoid SwiftPM resource bundles here — a nested
        // resource .bundle breaks the .app's code signature, which in turn stops
        // macOS from registering the app for notifications.

        // Bootstrap the view-model: attempt silent auto-login using the stored
        // keychain token for the most-recently-used server profile.
        Task { @MainActor in
            await appVM.bootstrap()
        }

        // Request notification permission once at startup.
        Task { @MainActor in
            await SystemNotifications.requestPermissionIfNeeded()
        }

        // Wire up the native menu bar.
        buildMainMenu()

        // Set up the menu-bar status item.
        setupStatusItem()
    }

    // Closing the (only) window must NOT quit the app — see windowShouldClose.
    // Quit happens only via ⌘Q / the menu-bar "退出" item.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    // Clicking the Dock icon (or reopening) with no visible window re-shows it
    // instead of doing nothing — the window still exists, just hidden.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { showMainWindow() }
        return true
    }

    // MARK: - NSWindowDelegate

    /// Red close button → hide the window (orderOut) and return false so the
    /// window object survives. WeChat-style: the app keeps running in the Dock /
    /// menu bar and the window pops back via the Dock icon or the status item.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }

    /// Bring the main window back to the front (used by the Dock-reopen and the
    /// status-item "显示" action).
    private func showMainWindow() {
        if let window = mainWindow ?? NSApp.windows.first {
            window.makeKeyAndOrderFront(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Status item setup

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.isVisible = true

        // Subtle monochrome SF Symbol bubble (template = adapts to the menu bar's
        // light/dark appearance) — the colored app icon was too loud up here.
        if let image = NSImage(systemSymbolName: "bubble.left.fill",
                               accessibilityDescription: "Claude Chat") {
            let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
            let configured = image.withSymbolConfiguration(config) ?? image
            configured.isTemplate = true
            item.button?.image = configured
        }
        item.button?.toolTip = "Claude Chat"

        // Build the right-click menu, but DON'T assign it to `item.menu` — doing
        // so makes BOTH clicks open the menu. We keep it aside and pop it up
        // manually on right-click, leaving left-click free to show the window.
        let menu = NSMenu()
        let showItem = NSMenuItem(title: "显示 Claude Chat",
                                  action: #selector(handleStatusShowWindow),
                                  keyEquivalent: "")
        showItem.target = self
        menu.addItem(showItem)
        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "退出",
                                  action: #selector(NSApplication.terminate(_:)),
                                  keyEquivalent: "q")
        quitItem.keyEquivalentModifierMask = .command
        menu.addItem(quitItem)
        statusMenu = menu

        // Left-click → show window; right-click → pop the menu. Routed through
        // statusItemClicked(_:) which inspects the current event type.
        if let button = item.button {
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        statusItem = item

        // Poll unread counts every second and update the badge title.
        unreadPollTimer = Timer.scheduledTimer(withTimeInterval: 1.0,
                                              repeats: true) { [weak self] _ in
            // Timer fires on the main run loop, but the callback is not
            // automatically isolated to @MainActor.  Use DispatchQueue.main
            // rather than Task { @MainActor } to avoid a potential retain cycle
            // with self while crossing actor boundaries.
            DispatchQueue.main.async { [weak self] in
                self?.updateStatusBadge()
            }
        }
        // Run an initial update immediately so the badge is correct at launch.
        updateStatusBadge()
    }

    /// Refresh the status-item button title to reflect the current total unread count.
    private func updateStatusBadge() {
        guard let button = statusItem?.button else { return }
        let total = appVM.totalUnread
        if total <= 0 {
            button.title = ""
        } else if total > 99 {
            button.title = " 99+"
        } else {
            button.title = " \(total)"
        }
    }

    // MARK: - Status item actions

    /// Single entry point for status-item clicks. Left-click shows the window;
    /// right-click (or ctrl-click) pops the menu under the button.
    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        let isRightClick = event?.type == .rightMouseUp
            || (event?.modifierFlags.contains(.control) == true)
        if isRightClick, let menu = statusMenu, let item = statusItem {
            // Temporarily attach the menu so the button highlights and the menu
            // pops up at the right place, then detach so left-click stays free.
            item.menu = menu
            sender.performClick(nil)
            item.menu = nil
        } else {
            showMainWindow()
        }
    }

    @objc private func handleStatusShowWindow(_ sender: Any?) {
        showMainWindow()
    }

    @objc private func handleStatusClick(_ sender: Any?) {
        handleStatusShowWindow(sender)
    }

    // MARK: - Menu actions

    @objc private func openPreferences(_ sender: Any?) {
        NotificationCenter.default.post(name: .openPreferencesRequested, object: nil)
    }

    @objc private func newChat(_ sender: Any?) {
        NotificationCenter.default.post(name: .newChatRequested, object: nil)
    }

    @objc private func setFontSizeSmall(_ sender: Any?) {
        postFontSize(.small)
    }

    @objc private func setFontSizeMedium(_ sender: Any?) {
        postFontSize(.medium)
    }

    @objc private func setFontSizeLarge(_ sender: Any?) {
        postFontSize(.large)
    }

    @objc private func setFontSizeExtraLarge(_ sender: Any?) {
        postFontSize(.extraLarge)
    }

    @objc private func switchSession(_ sender: NSMenuItem) {
        // tag stores 1-based session index; convert to 0-based.
        let index = sender.tag - 1
        NotificationCenter.default.post(
            name: .switchSessionRequested,
            object: nil,
            userInfo: ["index": index]
        )
    }

    // MARK: - Helpers

    private func postFontSize(_ size: AppFontSize) {
        NotificationCenter.default.post(
            name: .fontSizeChanged,
            object: nil,
            userInfo: ["size": size]
        )
        // Update the settings object so the checkmarks stay in sync.
        appSettings.chatFontSize = size
        updateFontSizeCheckmarks()
    }

    // MARK: - Menu construction

    private func buildMainMenu() {
        let mainMenu = NSMenu(title: "MainMenu")

        // ── App menu ─────────────────────────────────────────────────────────
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu(title: "Claude Chat")
        appMenuItem.submenu = appMenu

        appMenu.addItem(withTitle: "About Claude Chat",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                        keyEquivalent: "")

        appMenu.addItem(.separator())

        let prefsItem = NSMenuItem(title: "Preferences…",
                                   action: #selector(openPreferences(_:)),
                                   keyEquivalent: ",")
        prefsItem.target = self
        appMenu.addItem(prefsItem)

        appMenu.addItem(.separator())

        appMenu.addItem(withTitle: "Quit Claude Chat",
                        action: #selector(NSApplication.terminate(_:)),
                        keyEquivalent: "q")

        // ── File menu ─────────────────────────────────────────────────────────
        let fileMenuItem = NSMenuItem()
        mainMenu.addItem(fileMenuItem)
        let fileMenu = NSMenu(title: "File")
        fileMenuItem.submenu = fileMenu

        let newChatItem = NSMenuItem(title: "New Chat",
                                     action: #selector(newChat(_:)),
                                     keyEquivalent: "n")
        newChatItem.target = self
        fileMenu.addItem(newChatItem)

        // ── Edit menu ─────────────────────────────────────────────────────────
        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "Edit")
        editMenuItem.submenu = editMenu

        editMenu.addItem(NSMenuItem(title: "Cut",
                                    action: #selector(NSText.cut(_:)),
                                    keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: "Copy",
                                    action: #selector(NSText.copy(_:)),
                                    keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "Paste",
                                    action: #selector(NSText.paste(_:)),
                                    keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: "Select All",
                                    action: #selector(NSText.selectAll(_:)),
                                    keyEquivalent: "a"))

        // ── View menu ─────────────────────────────────────────────────────────
        let viewMenuItem = NSMenuItem()
        mainMenu.addItem(viewMenuItem)
        let viewMenu = NSMenu(title: "View")
        viewMenuItem.submenu = viewMenu

        let fontSizeMenuItem = NSMenuItem(title: "Font Size", action: nil, keyEquivalent: "")
        viewMenu.addItem(fontSizeMenuItem)
        let fontSizeSubMenu = NSMenu(title: "Font Size")
        fontSizeMenuItem.submenu = fontSizeSubMenu

        let smallItem = NSMenuItem(title: AppFontSize.small.label,
                                   action: #selector(setFontSizeSmall(_:)),
                                   keyEquivalent: "")
        smallItem.tag = AppFontSize.small.rawValue
        smallItem.target = self
        fontSizeSubMenu.addItem(smallItem)

        let mediumItem = NSMenuItem(title: AppFontSize.medium.label,
                                    action: #selector(setFontSizeMedium(_:)),
                                    keyEquivalent: "")
        mediumItem.tag = AppFontSize.medium.rawValue
        mediumItem.target = self
        fontSizeSubMenu.addItem(mediumItem)

        let largeItem = NSMenuItem(title: AppFontSize.large.label,
                                   action: #selector(setFontSizeLarge(_:)),
                                   keyEquivalent: "")
        largeItem.tag = AppFontSize.large.rawValue
        largeItem.target = self
        fontSizeSubMenu.addItem(largeItem)

        let extraLargeItem = NSMenuItem(title: AppFontSize.extraLarge.label,
                                        action: #selector(setFontSizeExtraLarge(_:)),
                                        keyEquivalent: "")
        extraLargeItem.tag = AppFontSize.extraLarge.rawValue
        extraLargeItem.target = self
        fontSizeSubMenu.addItem(extraLargeItem)

        // ── Window menu ───────────────────────────────────────────────────────
        let windowMenuItem = NSMenuItem()
        mainMenu.addItem(windowMenuItem)
        let windowMenu = NSMenu(title: "Window")
        windowMenuItem.submenu = windowMenu
        NSApp.windowsMenu = windowMenu

        windowMenu.addItem(NSMenuItem(title: "Minimize",
                                      action: #selector(NSWindow.miniaturize(_:)),
                                      keyEquivalent: "m"))
        windowMenu.addItem(NSMenuItem(title: "Zoom",
                                      action: #selector(NSWindow.zoom(_:)),
                                      keyEquivalent: ""))

        windowMenu.addItem(.separator())

        let switchMenuItem = NSMenuItem(title: "Switch Session", action: nil, keyEquivalent: "")
        windowMenu.addItem(switchMenuItem)
        let switchSubMenu = NSMenu(title: "Switch Session")
        switchMenuItem.submenu = switchSubMenu

        for i in 1...9 {
            let item = NSMenuItem(title: "Session \(i)",
                                  action: #selector(switchSession(_:)),
                                  keyEquivalent: "\(i)")
            item.tag = i         // tag is 1-based; switchSession(_:) converts to 0-based
            item.target = self
            switchSubMenu.addItem(item)
        }

        // ── Help menu ─────────────────────────────────────────────────────────
        let helpMenuItem = NSMenuItem()
        mainMenu.addItem(helpMenuItem)
        let helpMenu = NSMenu(title: "Help")
        helpMenuItem.submenu = helpMenu
        NSApp.helpMenu = helpMenu

        // Placeholder — future help items go here.

        // Install the menu.
        NSApp.mainMenu = mainMenu

        // Sync font-size checkmarks with current setting.
        updateFontSizeCheckmarks()
    }

    /// Tick the checkmark next to the currently active font size in the
    /// View > Font Size submenu.
    private func updateFontSizeCheckmarks() {
        guard let mainMenu = NSApp.mainMenu else { return }
        // View menu is at index 3 (0=App, 1=File, 2=Edit, 3=View).
        guard let fontSizeMenu = mainMenu.item(at: 3)?.submenu?.item(at: 0)?.submenu else { return }
        let currentSize = appSettings.chatFontSize
        for item in fontSizeMenu.items {
            item.state = (item.tag == currentSize.rawValue) ? .on : .off
        }
    }
}
