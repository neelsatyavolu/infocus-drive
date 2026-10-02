import UIKit

/// Lexend in the system bars and lists (the bars themselves stay system glass).
@MainActor
enum SystemAppearance {
    static func apply() {
        let bar = UINavigationBar.appearance()
        bar.titleTextAttributes = [.font: lexend(17, .semibold), .foregroundColor: Brand.uiText]
        bar.largeTitleTextAttributes = [.font: lexend(32, .semibold), .foregroundColor: Brand.uiText]

        let tab = UITabBarAppearance()
        tab.configureWithDefaultBackground()
        for item in [tab.stackedLayoutAppearance, tab.inlineLayoutAppearance, tab.compactInlineLayoutAppearance] {
            item.normal.titleTextAttributes = [.font: lexend(10, .medium)]
            item.selected.titleTextAttributes = [.font: lexend(10, .medium)]
        }
        UITabBar.appearance().standardAppearance = tab
        UITabBar.appearance().scrollEdgeAppearance = tab

        UISegmentedControl.appearance().setTitleTextAttributes([.font: lexend(13, .medium)], for: .normal)
    }

    /// The bundled variable Lexend at a weight.
    static func lexend(_ size: CGFloat, _ weight: UIFont.Weight) -> UIFont {
        let descriptor = UIFontDescriptor(fontAttributes: [.family: "Lexend"])
            .addingAttributes([.traits: [UIFontDescriptor.TraitKey.weight: weight]])
        let font = UIFont(descriptor: descriptor, size: size)
        return font.familyName == "Lexend" ? font : .systemFont(ofSize: size, weight: weight)
    }
}
