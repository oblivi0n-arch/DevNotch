import SwiftUI
import AppKit

class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var statusItem: NSStatusItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let screen = getBuiltInScreen() else { return }

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

        let contentView = NotchContentView(notchWidth: notchWidth, notchHeight: notchHeight)

        let hostingView = NSHostingView(rootView: contentView)
        hostingView.frame = NSRect(x: 0, y: 0, width: windowWidth, height: windowHeight)
        window.contentView = hostingView

        window.makeKeyAndOrderFront(nil)
        
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "chevron.down.square", accessibilityDescription: "DevNotch")
        
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q"))
        statusItem.menu = menu
    }
    
    @objc private func quitApp() {
        NSApplication.shared.terminate(nil)
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
