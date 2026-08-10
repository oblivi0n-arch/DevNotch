import Foundation
import AppKit
import Combine

nonisolated enum DevApp: Equatable {
    case xcode
    case terminal
}

nonisolated enum AppMode: Equatable {
    case dev(DevApp)
    case neutral
}

final class AppModeService: ObservableObject {
    @Published private(set) var mode: AppMode = .neutral

    private let bundleIDToDevApp: [String: DevApp] = [
        "com.apple.dt.Xcode": .xcode,
        "com.apple.Terminal": .terminal
    ]

    private var workspaceObserver: NSObjectProtocol?
    private var didStart = false

    init() {}

    func start() {
        guard !didStart else { return }
        didStart = true

        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.handleActivation(notification)
        }

        recomputeFromFrontmostApp()
    }

    deinit {
        if let observer = workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }

    private func handleActivation(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              let bundleID = app.bundleIdentifier else {
            mode = .neutral
            return
        }
        updateMode(for: bundleID)
    }

    private func recomputeFromFrontmostApp() {
        guard let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else {
            mode = .neutral
            return
        }
        updateMode(for: bundleID)
    }

    private func updateMode(for bundleID: String) {
        guard bundleID != Bundle.main.bundleIdentifier else { return }

        if let devApp = bundleIDToDevApp[bundleID] {
            mode = .dev(devApp)
        } else {
            mode = .neutral
        }
    }
}
