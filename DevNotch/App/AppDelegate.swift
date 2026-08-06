import SwiftUI
import AppKit

class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var statusItem: NSStatusItem!
    var popover: NSPopover!

    private var ollamaIdleTimer: Timer?
    private let ollamaIdleTimeout: TimeInterval = 5 * 60
    
    let appModeService = AppModeService()
    lazy var gitService = GitStatusService(appModeService: appModeService)

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let screen = getBuiltInScreen() else { return }
        
        UserDefaults.standard.register(defaults: ["autoStartOllama": true])
        appModeService.start()
        gitService.start()

        let windowWidth: CGFloat = 320
        let windowHeight: CGFloat = 100

        let screenFrame = screen.frame
        let xPos = screenFrame.origin.x + (screenFrame.width - windowWidth) / 2
        let yPos = screenFrame.origin.y + screenFrame.height - windowHeight

        window = NSWindow(
            contentRect: NSRect(x: xPos, y: yPos, width: windowWidth, height: windowHeight),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        window.level = .statusBar
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.collectionBehavior = [.canJoinAllSpaces, .stationary]

        let notchWidth = getNotchWidth(screen: screen)
        let notchHeight = screen.safeAreaInsets.top

        let contentView = NotchContentView(
            notchWidth: notchWidth,
            notchHeight: notchHeight,
            appModeService: appModeService,
            gitService: gitService
        )

        let hostingView = NSHostingView(rootView: contentView)
        hostingView.frame = NSRect(x: 0, y: 0, width: windowWidth, height: windowHeight)
        window.contentView = hostingView

        window.makeKeyAndOrderFront(nil)
        
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "chevron.down.square", accessibilityDescription: "DevNotch")
        statusItem.button?.action = #selector(statusItemClicked(_:))
        statusItem.button?.target = self
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])

        popover = NSPopover()
        popover.delegate = self
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 320, height: 400)
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        OllamaLauncher.shared.stopIfWeStartedIt()
    }
    
    @objc private func quitApp() {
        NSApplication.shared.terminate(nil)
    }
    
    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }

        if event.type == .rightMouseUp {
            showQuitMenu()
        } else {
            togglePopover()
        }
    }

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

    private func showQuitMenu() {
        let menu = NSMenu()

        let checkItem = NSMenuItem(title: "Look for active repo", action: #selector(lookForActiveRepo), keyEquivalent: "r")
        checkItem.target = self
        menu.addItem(checkItem)

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q"))

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func lookForActiveRepo() {
        gitService.checkForActiveRepo()
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

    private func getNotchWidth(screen: NSScreen) -> CGFloat {
        if #available(macOS 12.0, *) {
            guard let left = screen.auxiliaryTopLeftArea,
                  let right = screen.auxiliaryTopRightArea else {
                return 0
            }
            let notch = screen.frame.width - left.width - right.width
            return max(notch, 0)
        }
        return 0
    }
}

extension AppDelegate: NSPopoverDelegate {
    func popoverDidClose(_ notification: Notification) {
        scheduleOllamaIdleShutdown()
    }
}
