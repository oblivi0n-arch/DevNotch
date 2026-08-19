import SwiftUI
import AppKit
import Combine

class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow?
    var statusItem: NSStatusItem!
    var popover: NSPopover!

    private var settingsWindow: NSWindow?

    private var ollamaIdleTimer: Timer?
    private let ollamaIdleTimeout: TimeInterval = 5 * 60

    private let overlayHeight: CGFloat = 200
    private let islandTopGap: CGFloat = 6

    private var appearanceCancellable: AnyCancellable?
    private var screenObserver: NSObjectProtocol?
    private var spaceObserver: NSObjectProtocol?

    let appearanceSettings = AppearanceSettings()
    let appModeService = AppModeService()
    lazy var gitService = GitStatusService(appModeService: appModeService)

    func applicationDidFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.register(defaults: ["autoStartOllama": true])
        appModeService.start()
        gitService.start()

        rebuildOverlayWindow()

        appearanceCancellable = appearanceSettings.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.rebuildOverlayWindow()
            }

        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.rebuildOverlayWindow()
            }
        }

        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.rebuildOverlayWindow()
            }
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "chevron.down.square", accessibilityDescription: "DevNotch")
        statusItem.button?.action = #selector(statusItemClicked(_:))
        statusItem.button?.target = self
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])

        popover = NSPopover()
        popover.delegate = self
        popover.behavior = .transient
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
        }
        if let spaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(spaceObserver)
        }
        OllamaLauncher.shared.stopIfWeStartedIt()
    }

    // MARK: - Overlay window

    private func rebuildOverlayWindow() {
        guard let screen = getBuiltInScreen() else {
            window?.orderOut(nil)
            return
        }

        let metrics = ScreenMetrics.measure(screen)
        let style = appearanceSettings.preference.resolved(hasNotch: metrics.hasNotch)
        let topOffset: CGFloat = style == .island ? metrics.menuBarHeight + islandTopGap : 0

        let screenFrame = screen.frame
        let frame = NSRect(
            x: screenFrame.origin.x,
            y: screenFrame.origin.y + screenFrame.height - overlayHeight - topOffset,
            width: screenFrame.width,
            height: overlayHeight
        )

        let overlay = window ?? makeOverlayWindow(frame: frame)
        window = overlay
        overlay.setFrame(frame, display: true)

        let contentView = NotchContentView(
            style: style,
            metrics: metrics,
            position: appearanceSettings.position,
            hideOutsideDevApps: appearanceSettings.hideOutsideDevApps,
            windowFrame: frame,
            appModeService: appModeService,
            gitService: gitService
        )

        let hostingView = NSHostingView(rootView: contentView)
        hostingView.frame = NSRect(origin: .zero, size: frame.size)
        hostingView.autoresizingMask = [.width, .height]
        overlay.contentView = hostingView
        overlay.orderFrontRegardless()
    }

    private func makeOverlayWindow(frame: NSRect) -> NSWindow {
        let overlay = NSWindow(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        overlay.level = .statusBar
        overlay.isOpaque = false
        overlay.backgroundColor = .clear
        overlay.hasShadow = false
        overlay.ignoresMouseEvents = true
        overlay.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]

        return overlay
    }

    private func getBuiltInScreen() -> NSScreen? {
        for screen in NSScreen.screens {
            if let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
                let displayID = CGDirectDisplayID(screenNumber.uint32Value)
                if CGDisplayIsBuiltin(displayID) != 0 {
                    return screen
                }
            }
        }
        return NSScreen.main
    }

    // MARK: - Status item

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }

        if event.type == .rightMouseUp {
            showContextMenu()
        } else {
            togglePopover()
        }
    }

    private func showContextMenu() {
        let menu = NSMenu()

        let checkItem = NSMenuItem(title: "Look for active repo", action: #selector(lookForActiveRepo), keyEquivalent: "r")
        checkItem.target = self
        menu.addItem(checkItem)

        menu.addItem(NSMenuItem.separator())

        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func lookForActiveRepo() {
        gitService.checkForActiveRepo()
    }

    @objc private func quitApp() {
        NSApplication.shared.terminate(nil)
    }

    // MARK: - Settings

    @objc private func openSettings() {
        if settingsWindow == nil {
            let detectedNotch = getBuiltInScreen().map { ScreenMetrics.measure($0).hasNotch } ?? false

            let hosting = NSHostingController(
                rootView: SettingsView(appearance: appearanceSettings, detectedNotch: detectedNotch)
            )

            let settings = NSWindow(contentViewController: hosting)
            settings.title = "DevNotch Settings"
            settings.styleMask = [.titled, .closable]
            settings.isReleasedWhenClosed = false
            settings.isOpaque = false
            settings.backgroundColor = .clear
            settings.titleVisibility = .visible
            settings.hasShadow = true
            settings.isMovableByWindowBackground = true

            settings.center()

            settingsWindow = settings
        }

        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
    
    // MARK: - Popover

    private func togglePopover() {
        guard let button = statusItem.button else { return }

        if popover.isShown {
            popover.performClose(nil)
        } else {
            cancelOllamaIdleShutdown()
            Task { await OllamaLauncher.shared.startIfNeeded() }

            popover.contentViewController = NSHostingController(rootView: OllamaChatView(gitService: gitService))
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    private func scheduleOllamaIdleShutdown() {
        ollamaIdleTimer?.invalidate()
        ollamaIdleTimer = Timer.scheduledTimer(withTimeInterval: ollamaIdleTimeout, repeats: false) { _ in
            Task { @MainActor in
                OllamaLauncher.shared.stopIfWeStartedIt()
            }
        }
    }

    private func cancelOllamaIdleShutdown() {
        ollamaIdleTimer?.invalidate()
        ollamaIdleTimer = nil
    }
}

extension AppDelegate: NSPopoverDelegate {
    func popoverDidClose(_ notification: Notification) {
        scheduleOllamaIdleShutdown()
    }
}
