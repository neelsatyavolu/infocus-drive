import SwiftUI

/// "Re-set the anchors on the virtual set" on Start and Redo, like the Portal's
/// `RecompositeCheckbox`: the editor re-composites every shot onto the clean set. Experimental.
struct RecompositeToggle: View {
    @Binding var isOn: Bool
    var disabled = false

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(ShowEditRules.recompositeLabel).font(.small).foregroundStyle(Brand.foreground)
                Text(ShowEditRules.recompositeHelp).font(.lexend(12, relativeTo: .caption)).foregroundStyle(Brand.muted)
            }
        }
        .tint(Brand.fill)
        .disabled(disabled)
    }
}
