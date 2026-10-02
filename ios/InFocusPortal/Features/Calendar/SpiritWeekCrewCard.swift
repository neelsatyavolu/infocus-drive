import SwiftUI

/// A Spirit Week day's theme and crew lists (brunch, lunch, night rally filmers, editors),
/// as the Portal's calendar shows them. The old unsorted "Filmers" list can only shrink:
/// producers sort those people into the lists below.
struct SpiritWeekCrewCard: View {
    let day: CalendarDay
    let spirit: CalendarMonth.SpiritWeekDay
    let members: [String]
    let busy: Bool
    @Binding var picker: NamePickerRequest?
    let save: (_ role: String, _ names: [String]) -> Void

    static let labels = [
        "Filmers": "Filmers (unsorted)", "Brunch Filmers": "Brunch filmers", "Lunch Filmers": "Lunch filmers",
        "Night Rally Filmers": "Night rally filmers", "Editors": "Editors",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Eyebrow("Spirit Week", color: Brand.muted)
                Text(spirit.theme).font(.lexend(17, .semibold, relativeTo: .headline)).foregroundStyle(Brand.green)
            }
            let unsorted = day.names(for: "Filmers")
            if !unsorted.isEmpty {
                list("Filmers", names: unsorted, hint: "Add each person to a list below to sort them.")
            }
            ForEach(spirit.crewRoles, id: \.self) { role in
                list(role, names: day.names(for: role), hint: nil)
            }
        }
        .card()
    }

    private func list(_ role: String, names: [String], hint: String?) -> some View {
        let label = Self.labels[role] ?? role
        return VStack(alignment: .leading, spacing: 8) {
            Text(label.uppercased())
                .font(.lexend(11, .medium, relativeTo: .caption2))
                .tracking(1.4)
                .foregroundStyle(Brand.muted)
            if let hint { Text(hint).font(.small).foregroundStyle(Brand.muted) }
            if names.isEmpty && role == "Filmers" {
                Text("Not set").font(.small).foregroundStyle(Brand.muted)
            }
            CrewChips(names: names, addLabel: role == "Filmers" ? nil : "Add", disabled: busy,
                      onRemove: { name in save(role, names.filter { $0 != name }) },
                      onAdd: {
                          picker = NamePickerRequest(title: label, names: members, current: "", allowsNobody: false,
                                                     block: { CastEligibility.listBlock($0, listed: names) },
                                                     onPick: { name in save(role, names + [name]) })
                      })
        }
    }
}
