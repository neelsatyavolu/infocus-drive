import SwiftUI

/// A birthday: month and day, no year (`app/api/profile/route.ts`, `src/lib/birthdays.ts`).
struct Birthday: Encodable, Equatable, Sendable {
    let month: Int
    let day: Int

    static let monthNames = ["January", "February", "March", "April", "May", "June", "July",
                             "August", "September", "October", "November", "December"]

    /// Days in each month, with February's 29th allowed (the Portal's `DAYS_IN_MONTH`).
    private static let daysInMonth = [31, 29, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]

    /// Days `month` can have; 31 when no month is picked (0).
    static func days(inMonth month: Int) -> Int {
        (1...12).contains(month) ? daysInMonth[month - 1] : 31
    }

    static func isValid(month: Int, day: Int) -> Bool {
        (1...12).contains(month) && day >= 1 && day <= daysInMonth[month - 1]
    }

    /// Picking a month keeps the day only if that month has it (no February 30); 0 is unset.
    static func day(_ day: Int, keptFor month: Int) -> Int {
        day > days(inMonth: month) ? 0 : day
    }

    /// What the pickers say to save (0 is unset in either).
    enum Draft: Equatable {
        case set(Birthday), clear, incomplete
    }

    static func draft(month: Int, day: Int) -> Draft {
        if month == 0, day == 0 { return .clear }
        guard month != 0, day != 0 else { return .incomplete }
        return isValid(month: month, day: day) ? .set(Birthday(month: month, day: day)) : .incomplete
    }

    /// The saved birthday, if the profile has a whole one.
    static func saved(_ profile: ProfileInfo?) -> Birthday? {
        guard let month = profile?.birthdayMonth, let day = profile?.birthdayDay,
              isValid(month: month, day: day) else { return nil }
        return Birthday(month: month, day: day)
    }
}

/// `PATCH api/profile` body: `birthday` goes out as null to remove it (a missing key changes nothing).
struct BirthdayBody: Encodable {
    let birthday: Birthday?

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(birthday, forKey: .birthday)
    }

    private enum CodingKeys: String, CodingKey { case birthday }
}

/// Settings → Birthday: month and day, which the Portal shows on the Master Calendar.
struct BirthdaySection: View {
    @Binding var profile: ProfileInfo?
    @Environment(\.portalClient) private var client
    @State private var month = 0
    @State private var day = 0
    @State private var saving = false
    @State private var message: (text: String, error: Bool)?

    private var saved: Birthday? { Birthday.saved(profile) }
    private var unchanged: Bool { month == (saved?.month ?? 0) && day == (saved?.day ?? 0) }

    var body: some View {
        Section {
            Picker("Month", selection: $month) {
                Text("Not set").tag(0)
                ForEach(1...12, id: \.self) { Text(Birthday.monthNames[$0 - 1]).tag($0) }
            }
            .onChange(of: month) { _, value in day = Birthday.day(day, keptFor: value) }
            Picker("Day", selection: $day) {
                Text("Not set").tag(0)
                ForEach(1...Birthday.days(inMonth: month), id: \.self) { Text("\($0)").tag($0) }
            }
            HStack {
                if saving {
                    ProgressView()
                } else {
                    Button("Save birthday") { Task { await save(Birthday.draft(month: month, day: day)) } }
                        .disabled(unchanged)
                }
                Spacer()
                if saved != nil, !saving {
                    Button("Remove", role: .destructive) { Task { await save(.clear) } }
                }
            }
            .buttonStyle(.borderless)
            .frame(minHeight: 44)
            if let message {
                Text(message.text).font(.small).foregroundStyle(message.error ? Brand.danger : Brand.green)
            }
        } header: {
            Text("Birthday")
        } footer: {
            Text("Month and day only. It goes on the Master Calendar so nobody's birthday gets missed. On a weekend or a day off, it shows on the class day before.")
        }
        .disabled(profile == nil)
        .onChange(of: [profile?.birthdayMonth, profile?.birthdayDay], initial: true) {
            month = saved?.month ?? 0
            day = saved?.day ?? 0
        }
    }

    private func save(_ draft: Birthday.Draft) async {
        let birthday: Birthday?
        switch draft {
        case .incomplete:
            message = ("Pick both a month and a day, or neither.", true)
            return
        case .clear: birthday = nil
        case .set(let value): birthday = value
        }
        saving = true
        defer { saving = false }
        do {
            profile = try await SettingsService(client: client).saveBirthday(birthday)
            month = saved?.month ?? 0
            day = saved?.day ?? 0
            message = (birthday == nil ? "Removed." : "Saved.", false)
        } catch {
            message = (Loadable<Int>.message(for: error), true)
        }
    }
}
