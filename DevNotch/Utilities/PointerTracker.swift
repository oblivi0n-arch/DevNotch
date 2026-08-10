import AppKit
import Combine

@MainActor
final class PointerTracker: ObservableObject {
    @Published private(set) var isInside = false

    private var trackingFrame: NSRect = .zero
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var safetyTimer: Timer?

    private let monitoredEvents: NSEvent.EventTypeMask = [
        .mouseMoved,
        .leftMouseDragged,
        .rightMouseDragged
    ]

    func start() {
        guard globalMonitor == nil else { return }

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: monitoredEvents) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.evaluate()
            }
        }

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: monitoredEvents) { [weak self] event in
            MainActor.assumeIsolated {
                self?.evaluate()
            }
            return event
        }

        safetyTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.evaluate()
            }
        }

        evaluate()
    }

    func stop() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil

        safetyTimer?.invalidate()
        safetyTimer = nil

        isInside = false
    }

    func updateTrackingFrame(_ frame: NSRect) {
        guard frame != trackingFrame else { return }
        trackingFrame = frame
        evaluate()
    }

    private func evaluate() {
        let inside = !trackingFrame.isEmpty && trackingFrame.contains(NSEvent.mouseLocation)
        guard inside != isInside else { return }
        isInside = inside
    }
}
