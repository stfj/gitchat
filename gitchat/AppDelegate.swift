import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let appState = AppState.shared
    private var statusItem: NSStatusItem!
    private var statusMenu: NSMenu!
    private var mainWindow: NSWindow?
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        buildMainMenu()
        buildStatusItem()
        wireCallbacks()
        appState.bootstrap()
        // First run: nothing to sign in with yet, so bring up the window.
        if CredentialsVault.load() == nil {
            showMainWindow()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow()
        return true
    }

    // MARK: - Status item

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "bubble.left.and.bubble.right.fill",
                                   accessibilityDescription: "gitchat")
            button.imagePosition = .imageLeft
            button.target = self
            button.action = #selector(statusItemClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        statusMenu = NSMenu()
        statusMenu.addItem(withTitle: "Open gitchat", action: #selector(openMainWindowAction), keyEquivalent: "")
        statusMenu.addItem(withTitle: "New Issue…", action: #selector(newIssueAction), keyEquivalent: "")
        statusMenu.addItem(withTitle: "Sync Now", action: #selector(syncNowAction), keyEquivalent: "")
        statusMenu.addItem(.separator())
        statusMenu.addItem(withTitle: "Mark All as Read", action: #selector(markAllReadAction), keyEquivalent: "")
        statusMenu.addItem(.separator())
        statusMenu.addItem(withTitle: "Settings…", action: #selector(openSettingsAction), keyEquivalent: "")
        statusMenu.addItem(.separator())
        statusMenu.addItem(withTitle: "Quit gitchat", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    @objc private func statusItemClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            statusItem.menu = statusMenu
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
        } else {
            toggleMainWindow()
        }
    }

    /// Dropbox-style: icon plus a count when there are unread chats.
    func updateBadge(_ count: Int) {
        guard let button = statusItem?.button else { return }
        if count > 0 {
            button.attributedTitle = NSAttributedString(
                string: " \(count)",
                attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .bold)]
            )
        } else {
            button.title = ""
        }
    }

    // MARK: - Windows

    func showMainWindow() {
        if mainWindow == nil {
            let host = NSHostingController(rootView: RootView().environmentObject(appState))
            let w = NSWindow(contentViewController: host)
            w.title = "gitchat"
            w.titleVisibility = .hidden
            w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            w.setContentSize(NSSize(width: 1080, height: 700))
            w.minSize = NSSize(width: 820, height: 480)
            w.isReleasedWhenClosed = false
            w.delegate = self
            if !w.setFrameUsingName("gitchat.main") { w.center() }
            w.setFrameAutosaveName("gitchat.main")
            mainWindow = w
        }
        mainWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func toggleMainWindow() {
        if let w = mainWindow, w.isVisible, w.isKeyWindow {
            w.orderOut(nil)
        } else {
            showMainWindow()
        }
    }

    @objc func openSettingsAction() {
        if settingsWindow == nil {
            let host = NSHostingController(rootView: SettingsView().environmentObject(appState))
            let w = NSWindow(contentViewController: host)
            w.title = "gitchat Settings"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.center()
            settingsWindow = w
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // Hide instead of destroying the main window so state (scroll, drafts) survives.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if sender == mainWindow {
            sender.orderOut(nil)
            return false
        }
        return true
    }

    func windowDidBecomeKey(_ notification: Notification) {
        if (notification.object as? NSWindow) == mainWindow {
            appState.windowFocusChanged(isKey: true)
        }
    }

    func windowDidResignKey(_ notification: Notification) {
        if (notification.object as? NSWindow) == mainWindow {
            appState.windowFocusChanged(isKey: false)
        }
    }

    // MARK: - Wiring

    private func wireCallbacks() {
        appState.onUnreadChanged = { [weak self] count in
            self?.updateBadge(count)
        }
        appState.onShowWindow = { [weak self] in
            self?.showMainWindow()
        }
        Notifier.shared.onOpenChat = { [weak self] chatID in
            self?.appState.selectedChatID = chatID
            self?.appState.filter = .all
            self?.showMainWindow()
        }
        Notifier.shared.onReply = { [weak self] chatID, text in
            self?.appState.sendMessage(chatID: chatID, text: text, attachments: [])
        }
        Notifier.shared.shouldSuppressBanner = { [weak self] chatID in
            guard let self else { return false }
            return self.appState.selectedChatID == chatID && self.appState.windowIsKey
        }
    }

    // MARK: - Main menu (needed for ⌘C/⌘V etc. in an LSUIElement app)

    private func buildMainMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        appMenu.addItem(withTitle: "About gitchat",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Settings…", action: #selector(openSettingsAction), keyEquivalent: ",")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide gitchat", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit gitchat", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let fileItem = NSMenuItem()
        main.addItem(fileItem)
        let fileMenu = NSMenu(title: "File")
        fileItem.submenu = fileMenu
        fileMenu.addItem(withTitle: "New Issue", action: #selector(newIssueAction), keyEquivalent: "n")
        fileMenu.addItem(withTitle: "Sync Now", action: #selector(syncNowAction), keyEquivalent: "r")
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")

        let editItem = NSMenuItem()
        main.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editItem.submenu = editMenu
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Find", action: #selector(focusSearchAction), keyEquivalent: "f")

        let windowItem = NSMenuItem()
        main.addItem(windowItem)
        let windowMenu = NSMenu(title: "Window")
        windowItem.submenu = windowMenu
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "gitchat", action: #selector(openMainWindowAction), keyEquivalent: "0")

        NSApp.mainMenu = main
    }

    // MARK: - Actions

    @objc func openMainWindowAction() {
        showMainWindow()
    }

    @objc func newIssueAction() {
        showMainWindow()
        appState.composeVisible = true
    }

    @objc func syncNowAction() {
        appState.syncNow()
    }

    @objc func markAllReadAction() {
        appState.markAllRead()
    }

    @objc func focusSearchAction() {
        showMainWindow()
        NotificationCenter.default.post(name: .gcFocusSearch, object: nil)
    }
}
