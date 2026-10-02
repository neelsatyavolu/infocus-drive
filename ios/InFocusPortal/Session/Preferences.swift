import SwiftUI
import Observation

enum Appearance: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }
    var label: String { rawValue.capitalized }
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

/// What the person chose on this device, kept in UserDefaults.
@MainActor @Observable
final class Preferences {
    private let defaults: UserDefaults

    var appearance: Appearance { didSet { defaults.set(appearance.rawValue, forKey: Keys.appearance) } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        appearance = Appearance(rawValue: defaults.string(forKey: Keys.appearance) ?? "") ?? .system
    }

    private enum Keys {
        static let appearance = "appearance"
    }
}
