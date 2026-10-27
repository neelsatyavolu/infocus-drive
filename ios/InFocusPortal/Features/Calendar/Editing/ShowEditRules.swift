import Foundation

/// The Editing tab's words and rules, ported from the Portal (`src/lib/show-editor.ts`,
/// `show-editor-sources.ts`, `show-editor-views.ts` and `app/(app)/editing/`) so the app says
/// and picks exactly what the web page does.
enum ShowEditRules {
    static let noteMax = 500
    static let fixMax = 1000
    static let maxSources = 12
    static let recordingsShown = 6
    /// Shows go public at 8:30 AM Pacific on show day unless someone picks another time.
    static let usualPublishTime = "08:30"
    static let autoScheduleNote = "If nobody approves, it's scheduled automatically at 8:00 AM on show day."
    static let offlineNote = "The editing machine is offline. The job will start when it's back."

    static let stageLabels = [
        "download": "Downloading the recording",
        "analyze": "Finding the takes",
        "graphics": "Making fresh graphics",
        "audio": "Levelling the audio",
        "build": "Building the timeline",
        "render": "Rendering",
        "check": "Checking the render",
        "upload": "Uploading to Drive",
        "fix": "Applying the fix",
    ]

    // MARK: Times

    /// "Tue, Oct 27, 8:30 AM" in Pacific time, like the Portal.
    static func pacific(_ date: Date) -> String {
        var style = Date.FormatStyle.dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute()
        style.timeZone = ShowUploadRules.timeZone
        return date.formatted(style)
    }

    static func clock(_ date: Date) -> String {
        var style = Date.FormatStyle.dateTime.hour().minute()
        style.timeZone = ShowUploadRules.timeZone
        return date.formatted(style)
    }

    /// "just now", "12 min ago", "3 h ago", "2 days ago".
    static func lastSeen(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return "never" }
        let minutes = max(0, Int((now.timeIntervalSince(date) / 60).rounded()))
        if minutes < 1 { return "just now" }
        if minutes < 60 { return "\(minutes) min ago" }
        let hours = Int((Double(minutes) / 60).rounded())
        if hours < 48 { return "\(hours) h ago" }
        return "\(Int((Double(hours) / 24).rounded())) days ago"
    }

    // MARK: Status lines

    /// The header's editor tag.
    static func editorStatus(_ state: ShowEditState, now: Date = Date()) -> (tone: StatusTag.Tone, label: String) {
        guard !state.devices.isEmpty else { return (.danger, "No editor linked") }
        let worker = state.worker
        let version = worker.version.map { " · \($0)" } ?? ""
        let name = state.devices.first(where: \.active).map { " · \($0.name)" } ?? ""
        if !worker.online { return (.danger, "Editor offline\(name) · last seen \(lastSeen(worker.lastSeenAt, now: now))") }
        if let health = worker.health, !health.ok { return (.warning, "Editor needs attention\(name)\(version)") }
        return (.success, "Editor online\(name)\(worker.busy ? " · busy" : "")\(version)")
    }

    /// The edit card's tag: Not started, Editing: <stage>, Ready for review, Scheduled or Failed.
    static func summary(_ state: ShowEditState) -> (tone: StatusTag.Tone, label: String) {
        if state.sentToYouTube || state.job?.status == "PUBLISHED" { return (.success, "Scheduled") }
        switch state.job?.status {
        case "QUEUED": return (.neutral, "Editing: Waiting for the editing machine")
        case "RUNNING": return (.neutral, "Editing: " + (state.job?.stage.flatMap { stageLabels[$0] } ?? "Starting"))
        case "REVIEW": return (.warning, "Ready for review")
        case "FAILED": return (.danger, "Failed")
        default: return (.neutral, "Not started")
        }
    }

    /// While an edit runs: where it is.
    static func progress(_ job: ShowEditJob, waitingFor: String?) -> String {
        if job.status == "QUEUED" {
            if job.pendingFix != nil {
                return waitingFor.map { "Waiting for \($0) to come online (fix, v\(job.version + 1))" }
                    ?? "Fix waiting for the editing machine (v\(job.version + 1))"
            }
            return job.message ?? "Waiting for the editing machine"
        }
        let stage = job.stage.flatMap { stageLabels[$0] } ?? "Starting"
        let prefix = job.pendingFix != nil ? "Fixing (v\(job.version + 1)) · " : ""
        return prefix + stage + (job.message.map { ": \($0)" } ?? "")
    }

    static func packageNote(_ packages: [ShowEditState.QueuedPackage]) -> (warning: Bool, text: String) {
        if packages.isEmpty {
            return (true, "No package is queued for this show. If the anchors throw to one, queue it in the Publishing Queue before you start; otherwise the editor puts a placeholder there and flags it.")
        }
        let missing = packages.filter { !$0.ready }
        if !missing.isEmpty {
            let one = missing.count == 1
            let names = missing.map { "“\($0.title)”" }.joined(separator: ", ")
            return (true, "\(names) \(one ? "is" : "are") queued but \(one ? "has" : "have") no final cut uploaded, so the editor can't use \(one ? "it" : "them"). Upload the final cut in the Publishing Queue first.")
        }
        let names = packages.map { "“\($0.title)”" }.joined(separator: ", ")
        return (false, "\(packages.count == 1 ? "Package" : "Packages") from the Publishing Queue: \(names).")
    }

    static func announcementNote(_ count: Int?) -> (warning: Bool, text: String) {
        guard let count else {
            return (true, "This show has no Teleprompter script yet, so the editor will use the announcements as they were submitted. Each card is made from that text.")
        }
        if count == 0 {
            return (true, "The show's script has no announcements in A2. If the anchors read any, add them in the Teleprompter before you start: each card is made from that text.")
        }
        return (false, "\(count == 1 ? "1 announcement" : "\(count) announcements") in the show's script (A2).")
    }

    /// Auto-start's note above the recordings.
    static func autoStartNote(_ preview: ShowEditState.AutoStart?) -> (warning: Bool, text: String) {
        guard let preview else {
            return (false, "Auto-start is on. It starts this show once its recordings reach the Shows folder and stop changing for 10 minutes.")
        }
        let files = preview.files.map { "\($0.fileName) (\($0.role.label))" }.joined(separator: ", ")
        if let error = preview.error {
            return (true, "Auto-start found \(files), but can't use them: \(error) Pick the recordings below instead.")
        }
        if preview.ready || preview.readyAt == nil { return (false, "Auto-start will edit this show from \(files); it starts within 5 minutes.") }
        return (false, "Auto-start will edit this show from \(files) once its files have settled (about \(clock(preview.readyAt!))).")
    }

    /// Approve & schedule's line: what it will schedule and when, or why it can't yet.
    static func approveLine(_ approve: ShowEditState.Approve?) -> String {
        guard let approve else { return "Couldn't read the usual title and time. Use Change details on the Portal." }
        if let problem = approve.problem { return problem }
        let when = PortalJSON.date(from: approve.publishAt).map(pacific) ?? approve.publishAt
        return "Schedules “\(approve.title)” for \(when)."
    }

    /// Once the show was sent to YouTube: where it stands there.
    static func sentLine(_ published: ShowEditState.Published?) -> String {
        guard let published else { return "This show was sent to YouTube. Make changes in YouTube Studio." }
        let when = pacific(published.publishAt)
        switch published.status {
        case "UPLOADING", "PROCESSING", "FINALIZING": return "Sending it to YouTube now. It goes public \(when)."
        case "FAILED": return "Sending it to YouTube needs attention. Open Upload show to see why."
        case "LIVE": return "Public on YouTube since \(when). Make changes in YouTube Studio."
        default: return "Scheduled on YouTube for \(when). Make changes in YouTube Studio."
        }
    }

    /// Under the edited show: its version, when it finished and what it cost.
    static func details(_ job: ShowEditJob, sent: Bool) -> String {
        var parts = ["Version \(job.version)"]
        if let finished = job.finishedAt { parts.append("finished \(pacific(finished))") }
        if let cost = job.costUsd { parts.append("editing cost \(sent ? "" : "so far ")$" + String(format: "%.2f", cost)) }
        return parts.joined(separator: " · ")
    }

    /// What the editor reported about the files themselves (recordings, cameras, skipped copies).
    static func structure(_ decisions: [ShowEditJob.Decision]) -> [ShowEditJob.Decision] {
        decisions.filter { ["structure", "recordings"].contains($0.kind) }
    }

    // MARK: Recordings

    /// `InFocus Show MM-DD-YYYY[ Left|Center|Right][ (n)].mov|mp4`, named after the airing date.
    private static let showFile = #/^InFocus Show (\d{2})-(\d{2})-(\d{4})(?: (Left|Center|Right))?(?: \(\d+\))?\.(?:mov|mp4)$/#.ignoresCase()

    /// The airing date (`YYYY-MM-DD`) a recording is named after, or nil.
    static func showDate(fromName name: String) -> String? {
        guard let match = name.trimmingCharacters(in: .whitespaces).wholeMatch(of: showFile) else { return nil }
        return "\(match.3)-\(match.1)-\(match.2)"
    }

    /// A camera's name presets its role (Left L, Center M, Right R); anything else is Auto.
    static func role(fromName nameOrPath: String) -> ShowEditSource.Role {
        let name = (nameOrPath.split(separator: "/").last.map(String.init) ?? nameOrPath).trimmingCharacters(in: .whitespaces)
        switch name.wholeMatch(of: showFile)?.4?.lowercased() {
        case "left": return .L
        case "center": return .M
        case "right": return .R
        default: return .auto
        }
    }

    /// Why a file is never preselected, or nil: edited exports, and a copy of another show's file.
    static func exclusion(_ recording: ShowEditState.Recording, in all: [ShowEditState.Recording]) -> String? {
        if recording.name.range(of: "edited", options: .caseInsensitive) != nil { return "An edited export, not a recording" }
        guard let date = showDate(fromName: recording.name) else { return nil }
        let twin = all.first { other in
            guard other.path != recording.path, other.size == recording.size, let otherDate = showDate(fromName: other.name) else { return false }
            return otherDate != date
        }
        return twin.map { "Same size as \($0.name): probably a copy of another show" }
    }

    /// The show's finished recordings by name, oldest first, cameras on their role.
    static func defaultSelection(_ recordings: [ShowEditState.Recording], showDate date: String) -> [ShowEditSource] {
        recordings
            .filter { showDate(fromName: $0.name) == date && exclusion($0, in: recordings) == nil && $0.stable }
            .sorted { $0.modifiedAt < $1.modifiedAt }
            .prefix(maxSources)
            .map { ShowEditSource(path: $0.path, role: role(fromName: $0.name)) }
    }

    /// What's wrong with this choice of recordings, or nil when it can be edited.
    static func selectionError(_ sources: [ShowEditSource]) -> String? {
        if sources.isEmpty { return "Pick at least one recording." }
        if sources.count > maxSources { return "Pick at most \(maxSources) files." }
        if Set(sources.map(\.path)).count != sources.count { return "Pick each recording once." }
        if sources.allSatisfy({ $0.role == .ignore }) { return "Every file is set to Ignore. Use at least one." }
        return nil
    }

    /// Ticking a file adds it at the end (on its camera role, else Auto); ticking again removes it.
    static func toggle(_ selected: [ShowEditSource], path: String) -> [ShowEditSource] {
        if selected.contains(where: { $0.path == path }) { return selected.filter { $0.path != path } }
        return selected.count >= maxSources ? selected : selected + [ShowEditSource(path: path, role: role(fromName: path))]
    }

    /// Ticking a folder adds every finished file in it, or removes them all when they're all chosen.
    static func toggleFolder(_ selected: [ShowEditSource], files: [ShowEditState.Recording]) -> [ShowEditSource] {
        let usable = files.filter(\.stable).sorted { $0.modifiedAt < $1.modifiedAt }
        let chosen = Set(selected.map(\.path))
        if !usable.isEmpty, usable.allSatisfy({ chosen.contains($0.path) }) {
            let paths = Set(usable.map(\.path))
            return selected.filter { !paths.contains($0.path) }
        }
        let added = usable.filter { !chosen.contains($0.path) }.map { ShowEditSource(path: $0.path, role: role(fromName: $0.name)) }
        return Array((selected + added).prefix(maxSources))
    }

    static func setRole(_ selected: [ShowEditSource], path: String, role: ShowEditSource.Role) -> [ShowEditSource] {
        selected.map { $0.path == path ? ShowEditSource(path: $0.path, role: role) : $0 }
    }

    static func move(_ selected: [ShowEditSource], from index: Int, by offset: Int) -> [ShowEditSource] {
        let target = index + offset
        guard selected.indices.contains(index), selected.indices.contains(target) else { return selected }
        var next = selected
        next.swapAt(index, target)
        return next
    }

    /// Loose files first, then each subfolder of `Shows/` with its files.
    static func groups(_ recordings: [ShowEditState.Recording]) -> [(folder: String?, files: [ShowEditState.Recording])] {
        let loose = recordings.filter { $0.folder == nil }
        var order: [String] = []
        var folders: [String: [ShowEditState.Recording]] = [:]
        for recording in recordings {
            guard let folder = recording.folder else { continue }
            if folders[folder] == nil { order.append(folder) }
            folders[folder, default: []].append(recording)
        }
        var result: [(folder: String?, files: [ShowEditState.Recording])] = loose.isEmpty ? [] : [(folder: nil, files: loose)]
        for folder in order { result.append((folder: folder, files: folders[folder] ?? [])) }
        return result
    }

    /// Newest first: the newest 6 plus older ones already ticked; `hidden` counts the rest.
    static func visible(_ files: [ShowEditState.Recording], chosen: Set<String>, showAll: Bool) -> (shown: [ShowEditState.Recording], hidden: Int) {
        if showAll { return (files, 0) }
        let shown = files.enumerated().filter { $0.offset < recordingsShown || chosen.contains($0.element.path) }.map(\.element)
        return (shown, files.count - shown.count)
    }

    static func size(_ bytes: Double) -> String {
        bytes >= 1e9 ? String(format: "%.1f GB", bytes / 1e9) : "\(max(1, Int((bytes / 1e6).rounded()))) MB"
    }

    // MARK: Publish time

    /// A changed, complete publish slot to send with Start; nil keeps the usual time.
    static func publishSlot(_ date: Date, showDate: String) -> ShowEditAction.PublishSlot? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = ShowUploadRules.timeZone
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        guard let year = parts.year, let month = parts.month, let day = parts.day, let hour = parts.hour, let minute = parts.minute else { return nil }
        let slot = ShowEditAction.PublishSlot(date: String(format: "%04d-%02d-%02d", year, month, day),
                                              time: String(format: "%02d:%02d", hour, minute))
        return slot.date == showDate && slot.time == usualPublishTime ? nil : slot
    }

    /// 8:30 AM Pacific on show day.
    static func usualPublishDate(showDate: String) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = ShowUploadRules.timeZone
        let parts = showDate.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return Date() }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: 8, minute: 30)) ?? Date()
    }
}
