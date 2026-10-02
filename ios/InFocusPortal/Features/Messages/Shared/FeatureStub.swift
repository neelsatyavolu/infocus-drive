import Foundation

/// Messages, Equipment and Livestreams read stub data instead of the Portal while the
/// DEBUG launch argument `-InFocusStubSession` is set (simulator screenshots). Release
/// builds always talk to the Portal.
enum FeatureStub {
    static var isOn: Bool {
        #if DEBUG
        UserDefaults.standard.string(forKey: "InFocusStubSession") != nil
        #else
        false
        #endif
    }

    /// A short pause so stub screens show their loading state the way the Portal would.
    static func delay() async {
        try? await Task.sleep(nanoseconds: 250_000_000)
    }
}
