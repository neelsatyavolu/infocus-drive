import SwiftUI

/// Screens for `WorkRoute`.
struct WorkDestination: View {
    let route: WorkRoute

    var body: some View {
        switch route {
        case .group(let rowId, nil):
            GroupDetailScreen(rowId: rowId)
        case .group(let rowId, let slug?):
            if let stage = GroupStage(slug: slug) {
                GroupStageScreen(rowId: rowId, stage: stage, reviewStage: GroupStageScreen.reviewStage(fromSlug: slug))
            } else {
                PortalPageScreen(path: "groups/\(rowId)/\(slug)", title: "Group")
            }
        case .studentStage(let stage):
            switch stage {
            case .information:
                PortalPageScreen(path: stage.rawValue, title: stage.title)
            case .brainstorming:
                BrainstormScreen()
            case .aRoll, .initialCut, .finalCut:
                StudentStageScreen(stage: stage)
            }
        }
    }
}
