import SwiftUI

/// Information (`/information`): the cycle guide. The copy matches the Portal's
/// page word for word (`app/(app)/information/page.tsx`); only the layout differs.
struct CycleGuideScreen: View {
    struct Entry: Identifiable, Hashable {
        let marker: String?
        let title: String
        let body: String
        var id: String { title }
    }

    static let stages: [Entry] = [
        Entry(marker: nil, title: "Package Pitching",
              body: "Where students will pitch ideas to the producer for the upcoming package cycle. See the package pitching section for more information."),
        Entry(marker: "1", title: "Brainstorming & Proof of Contact",
              body: "In this stage, students are required to contact at least 3 possible interviewees. Students are also required to write up a brainstorm document complete with b-roll ideas, a-roll information, and a preliminary script. Please note that your script is expected to be completed with your final cut and will be included in your grade."),
        Entry(marker: "2", title: "A-roll/b-roll",
              body: "In this stage, students are expected to upload their a-roll and b-roll to the InFocus Drive. Students will not be strictly graded on timeliness on this stage but are encouraged to aim to turn it in on time."),
        Entry(marker: "3.1", title: "Initial Cut Stage 1",
              body: "In this stage, students are required to upload a polished draft cut to the InFocus Portal and inform their assigned producer. Students will receive feedback from that producer and then are expected to improve the package, submitting as many updated cuts as needed. Until your assigned producer approves your package, you may not move onto Stage 2."),
        Entry(marker: "3.2", title: "Initial Cut Stage 2",
              body: "In this stage, students’ packages will be sent off to our adviser. Like Stage 1, the adviser will give you feedback on your package. You are expected, like before, to make as many revisions as needed until you receive the adviser’s approval. Until the adviser approves your package, you may not move onto Stage 3."),
        Entry(marker: "3.3", title: "Initial Cut Stage 3",
              body: "In this final stage, students’ packages will be sent off to our our executive producer team. At least two executive producers will give you feedback on your package. You are expected, like before, to make as many revisions as needed until you receive the at least two executive producers’ approval. Until two executive producers approve your package, you may not submit your Final Cut."),
        Entry(marker: "4", title: "Final Cut",
              body: "At this stage, students are expected to have passed Stage 3 of the approval process and made any remaining changes. Students are then expected to submit their final cut, where the executive producer team will review your submitted package together and give you a grade within 1 week of submission. Your package will also be sent to the publishing queue."),
    ]

    static let pitching = [
        "At the start of every package cycle, we will have package pitching. This is when groups will present at least one idea from each category (news, feature, commentary) to the producers. Producers will assign a group to each topic to balance categories. Each group will also be assigned an associate producer to help them throughout the process.",
        "Each group will rank their 3 or more topics, and while it is likely that a group will receive their number 1 topic, this is not guaranteed. Additionally, groups and topics may be shuffled around at the producer's discretion.",
    ]

    static let pitchingNote =
        "You are not permitted to repeat group members consecutively. This means that every cycle, your group members should not have been part of your last cycle’s package group."

    static let approvalIntro =
        "Every package moves through a set review chain before it can publish, and each stage must sign off before it advances to the next. You cannot skip a stage."

    static let approval: [Entry] = [
        Entry(marker: nil, title: "Stage 1",
              body: "Your assigned producer must greenlight your package for it to move forward. If they deny it, revise and resubmit to them until it is greenlit."),
        Entry(marker: nil, title: "Stage 2",
              body: "The adviser. Once your assigned producer greenlights the package, it goes to him. If he gives the green light, the package is allowed to advance to the last stage. This stage also includes initial cut feedback given by the class."),
        Entry(marker: nil, title: "Stage 3",
              body: "Two executive producers must give the final sign-off before the package is permitted to air on our show. Please note that any executive producer can deny a package as well and send it back."),
    ]

    static let approvalNotes = [
        "Man-on-the-street packages are prohibited from being your primary package for a cycle. If you would like to produce one, please contact a producer first.",
        "For any packages with content that may be controversial, all executive producers must also approve before the package can move forward.",
    ]

    static let publishing =
        "Nothing is permitted to be published under the InFocus name until it has cleared all the above stages. There are exceptions for social media content, which must be directly approved by the Head of Creative & Content."

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Nameplate(eyebrow: "My package", title: "Cycle guide",
                          subtitle: "Stages of a cycle, package pitching, and the approval process.")
                panel("Stages of a Cycle") { entries(Self.stages) }
                panel("Package Pitching") {
                    ForEach(Self.pitching, id: \.self) { prose($0) }
                    note(Self.pitchingNote)
                }
                panel("Package Approval & Feedback Process") {
                    prose(Self.approvalIntro)
                    entries(Self.approval)
                    ForEach(Self.approvalNotes, id: \.self) { note($0) }
                    prose(Self.publishing)
                }
            }
            .padding(Brand.gutter)
        }
        .brandBackground()
        .navigationTitle("Cycle guide")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func panel(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.h3).foregroundStyle(Brand.foreground).accessibilityAddTraits(.isHeader)
            content()
        }
        .card()
    }

    private func entries(_ rows: [Entry]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                if index > 0 { Divider().overlay(Brand.line) }
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    if rows.contains(where: { $0.marker != nil }) {
                        Text(row.marker ?? "").font(.mono(12)).foregroundStyle(Brand.muted).frame(width: 28, alignment: .leading)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(row.title).font(.lexend(15, .semibold)).foregroundStyle(Brand.foreground)
                        prose(row.body)
                    }
                }
                .padding(.vertical, 12)
                .accessibilityElement(children: .combine)
            }
        }
    }

    private func prose(_ text: String) -> some View {
        Text(text).font(.bodyText).foregroundStyle(Brand.secondary).fixedSize(horizontal: false, vertical: true)
    }

    private func note(_ text: String) -> some View {
        Label { prose(text) } icon: { Image(systemName: "info.circle").foregroundStyle(Brand.muted) }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Brand.raised, in: RoundedRectangle(cornerRadius: Brand.radius))
    }
}
