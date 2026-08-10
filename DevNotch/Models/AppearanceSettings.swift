import AppKit
import Foundation
import Combine

enum NotchStyle: Equatable {
    case notch
    case island
}

struct ScreenMetrics: Equatable {
    var notchWidth: CGFloat = 0
    var notchHeight: CGFloat = 0
    var menuBarHeight: CGFloat = 24

    var hasNotch: Bool { notchWidth > 0 && notchHeight > 0 }

    static func measure(_ screen: NSScreen) -> ScreenMetrics {
        var metrics = ScreenMetrics()

        metrics.menuBarHeight = max(0, screen.frame.maxY - screen.visibleFrame.maxY)

        if let left = screen.auxiliaryTopLeftArea,
           let right = screen.auxiliaryTopRightArea {
            metrics.notchWidth = max(0, screen.frame.width - left.width - right.width)
            metrics.notchHeight = screen.safeAreaInsets.top
        }

        return metrics
    }
}

final class AppearanceSettings: ObservableObject {
    enum Preference: String, CaseIterable, Identifiable {
        case auto
        case notch
        case island

        var id: String { rawValue }

        var label: String {
            switch self {
            case .auto: return "Automatic"
            case .notch: return "Hug the notch"
            case .island: return "Floating island"
            }
        }

        var detail: String {
            switch self {
            case .auto:
                return "Hugs the notch on Macs that have one, and floats below the menu bar everywhere else."
            case .notch:
                return "Always sits flush with the top edge. On a Mac without a notch this overlaps the menu bar."
            case .island:
                return "Always floats just below the menu bar as a rounded pill, leaving menu bar items visible."
            }
        }

        func resolved(hasNotch: Bool) -> NotchStyle {
            switch self {
            case .auto: return hasNotch ? .notch : .island
            case .notch: return .notch
            case .island: return .island
            }
        }
    }

    enum Position: String, CaseIterable, Identifiable {
        case leading
        case center
        case trailing

        var id: String { rawValue }

        var label: String {
            switch self {
            case .leading: return "Left"
            case .center: return "Center"
            case .trailing: return "Right"
            }
        }
    }

    private static let styleKey = "notchDisplayStyle"
    private static let positionKey = "notchPosition"
    private static let hideKey = "hideOutsideDevApps"

    @Published var preference: Preference {
        didSet {
            guard preference != oldValue else { return }
            UserDefaults.standard.set(preference.rawValue, forKey: Self.styleKey)
        }
    }

    @Published var position: Position {
        didSet {
            guard position != oldValue else { return }
            UserDefaults.standard.set(position.rawValue, forKey: Self.positionKey)
        }
    }

    @Published var hideOutsideDevApps: Bool {
        didSet {
            guard hideOutsideDevApps != oldValue else { return }
            UserDefaults.standard.set(hideOutsideDevApps, forKey: Self.hideKey)
        }
    }

    init() {
        UserDefaults.standard.register(defaults: [Self.hideKey: true])

        let storedStyle = UserDefaults.standard.string(forKey: Self.styleKey)
        preference = storedStyle.flatMap(Preference.init(rawValue:)) ?? .auto

        let storedPosition = UserDefaults.standard.string(forKey: Self.positionKey)
        position = storedPosition.flatMap(Position.init(rawValue:)) ?? .center

        hideOutsideDevApps = UserDefaults.standard.bool(forKey: Self.hideKey)
    }
}
