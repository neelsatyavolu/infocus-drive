import Foundation

/// Fictional livestream schedule for `-InFocusStubSession` screenshots.
extension LivestreamService {
    static let stub: LivestreamService = {
        let abby = LivestreamPerson(id: "me", name: "Abby Example")
        let otto = LivestreamPerson(id: "otto", name: "Otto Example")
        let sage = LivestreamPerson(id: "sage", name: "Sage Example")
        let day: Double = 86_400
        let now = Date()
        func event(_ id: String, _ title: String, in days: Double, location: String, crew: [LivestreamPerson],
                   capacity: Int = 4, status: LivestreamEvent.Status = .scheduled,
                   availability: LivestreamEvent.Availability = .public, mine: SignupStatus? = nil) -> LivestreamEvent {
            let open = max(0, capacity - crew.count)
            return LivestreamEvent(
                id: id, title: title, startsAt: now.addingTimeInterval(days * day), location: location, status: status,
                availability: availability, hours: 3, capacity: capacity,
                notes: id == "football" ? "Arrive 45 minutes early to set up the press box cameras." : "",
                manager: sage, attendees: crew, attendeeCount: crew.count, openSlots: open,
                capacityTone: open == 0 ? .full : open == 1 ? .one : .open,
                mySignup: mine.map { LivestreamEvent.MySignup(id: "signup-\(id)", status: $0) }, pendingSignupCount: 1)
        }
        let events = [
            event("polo", "Varsity Water Polo vs Los Gatos", in: -6, location: "Paly Pool", crew: [abby, otto], status: .completed),
            event("football", "Varsity Football vs Burlingame", in: 2, location: "Viking Stadium", crew: [otto]),
            event("volley", "Girls Varsity Volleyball vs Cupertino", in: 4, location: "Peery Center", crew: [otto, sage, abby]),
            event("concert", "Fall Choir Concert", in: 9, location: "Performing Arts Center", crew: [otto, sage, abby, LivestreamPerson(id: "x", name: "Kai Example")],
                  availability: .unconfirmed),
            event("hockey", "JV Field Hockey vs Gunn", in: 12, location: "Cobb Field", crew: [], availability: .unlisted, mine: .pending),
        ]
        let schedule = LivestreamSchedule(
            semester: .init(label: "Fall 2026"), requiredHours: 8, canManage: true, canSignup: true, currentUserId: "me",
            mySignups: [LivestreamSignup(id: "signup-hockey", eventId: "hockey", status: .pending, availableFullEvent: true,
                                         note: "Can stay for the whole game", createdAt: now.addingTimeInterval(-day), user: nil, event: nil)],
            pendingSignups: [LivestreamSignup(id: "p1", eventId: "football", status: .pending, availableFullEvent: false,
                                              note: "Can run camera 2 for the first half", createdAt: now.addingTimeInterval(-3600),
                                              user: sage, event: .init(id: "football", title: "Varsity Football vs Burlingame",
                                                                       startsAt: now.addingTimeInterval(2 * day)))],
            events: events, canAppointManagers: true, canViewCompletion: true, managers: [sage])
        func row(_ person: LivestreamPerson, hours: Double, events: Int, scheduled: Double = 0) -> LivestreamCompletion.Row {
            let percent = min(100, Int(hours / 8 * 100))
            return LivestreamCompletion.Row(
                userId: person.id, name: person.name, email: nil, completedHours: hours, completedEvents: events, requiredHours: 8,
                isManager: false, managedEvents: 0, requiredManagedEvents: 2, creditPercent: percent, scheduledHours: scheduled,
                projectedPercent: min(100, Int((hours + scheduled) / 8 * 100)), points: Double(percent) / 10)
        }
        let completion = LivestreamCompletion(rows: [row(abby, hours: 3, events: 1, scheduled: 3), row(otto, hours: 9, events: 3)],
                                              completedEventCount: 1)
        let members = [abby, otto, sage].map { PortalMember(id: $0.id, name: $0.name, nickname: nil, email: nil) }
        return LivestreamService(
            schedule: { await FeatureStub.delay(); return schedule },
            requestSignup: { _, _ in await FeatureStub.delay(); SampleMode.notSaved() },
            review: { _, _ in await FeatureStub.delay(); SampleMode.notSaved() },
            saveEvent: { _, _ in await FeatureStub.delay(); SampleMode.notSaved() },
            deleteEvent: { _ in await FeatureStub.delay(); SampleMode.notSaved() },
            completion: { await FeatureStub.delay(); return completion },
            members: { await FeatureStub.delay(); return members },
            addManager: { _ in await FeatureStub.delay(); SampleMode.notSaved() },
            removeManager: { _ in await FeatureStub.delay(); SampleMode.notSaved() })
    }()
}
