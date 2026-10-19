import SwiftUI

/// Participation (`/participation`, every producer): score each class day and review docked
/// scores. It is the same view the Grade Editor shows on its Participation tab
/// (`ParticipationEntryView`), opened on its own for producers who don't manage grades.
struct ParticipationScreen: View {
    var body: some View {
        ParticipationEntryView()
            .padding(.top, 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .brandBackground()
            .navigationTitle("Participation")
            .navigationBarTitleDisplayMode(.inline)
    }
}
