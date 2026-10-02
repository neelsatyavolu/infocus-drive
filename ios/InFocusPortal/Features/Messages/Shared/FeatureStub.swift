import Foundation

/// Messages, Equipment and Livestreams read fictional data instead of the Portal in the
/// App Review sample app (`SampleMode`).
enum FeatureStub {
    static var isOn: Bool {
        SampleMode.isOn
    }

    /// A short pause so stub screens show their loading state the way the Portal would.
    static func delay() async {
        try? await Task.sleep(nanoseconds: 250_000_000)
    }
}
