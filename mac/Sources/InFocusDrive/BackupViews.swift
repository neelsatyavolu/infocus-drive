import SwiftUI

/// "Mac backup" in the Drive window: what's backed up where, the last result,
/// live progress and the settings.
struct BackupSection: View {
    @ObservedObject var drive: DriveController
    @ObservedObject var backup: BackupController

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionLabel(text: "Mac backup")
                Spacer()
                if backup.isConfigured, !backup.isRunning {
                    Button("Back up now") { backup.runNow() }
                        .buttonStyle(LinkButtonStyle())
                        .font(.lexend(12, .medium))
                }
            }
            VStack(alignment: .leading, spacing: 0) {
                if !backup.isConfigured {
                    intro
                    Rectangle().fill(Brand.border).frame(height: 1)
                }
                PathRow(symbol: "laptopcomputer", title: "From", value: sourceText,
                        action: "Choose…", enabled: !backup.isRunning) { backup.chooseSource() }
                Rectangle().fill(Brand.border).frame(height: 1)
                PathRow(symbol: "externaldrive", title: "To", value: destinationText,
                        action: "Choose…", enabled: drive.connectedVolume != nil && !backup.isRunning,
                        help: drive.connectedVolume == nil ? "Connect the Drive first" : nil) { backup.chooseDestination() }
                if backup.isConfigured {
                    Rectangle().fill(Brand.border).frame(height: 1)
                    BackupStatusRow(backup: backup).padding(.horizontal, 12).padding(.vertical, 10)
                    Rectangle().fill(Brand.border).frame(height: 1)
                    HStack(spacing: 10) {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.system(size: 12, weight: .medium)).foregroundStyle(Brand.muted).frame(width: 18)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Back up every hour").font(.lexend(12.5, .medium))
                            Text("Files deleted here leave the Drive after a week")
                                .font(.lexend(11)).foregroundStyle(Brand.muted)
                        }
                        Spacer(minLength: 8)
                        Toggle("", isOn: Binding(get: { backup.settings?.automatic ?? true }, set: { backup.setAutomatic($0) }))
                            .toggleStyle(.switch).controlSize(.mini).labelsHidden().tint(Brand.fill)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                }
            }
            .background(Brand.card)
            .overlay(Rectangle().strokeBorder(Brand.border))
        }
    }

    private var intro: some View {
        Text("Copies a folder on this Mac to the Drive every hour. Only new and changed files upload, so it's quick after the first time.")
            .font(.lexend(12))
            .foregroundStyle(Brand.muted)
            .fixedSize(horizontal: false, vertical: true)
            .padding(12)
    }

    private var sourceText: String? {
        guard let source = backup.settings?.source, !source.isEmpty else { return nil }
        let short = (source as NSString).abbreviatingWithTildeInPath
        return short == "~" ? "~ (your whole home folder)" : short
    }

    private var destinationText: String? {
        guard let settings = backup.settings, !settings.shareID.isEmpty else { return nil }
        return settings.remotePath.isEmpty ? settings.shareName : settings.shareName + "/" + settings.remotePath
    }
}

private struct PathRow: View {
    let symbol: String
    let title: String
    let value: String?
    let action: String
    let enabled: Bool
    var help: String?
    let run: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium)).foregroundStyle(Brand.muted).frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.lexend(12.5, .medium))
                Text(value ?? "Not chosen")
                    .font(value == nil ? .lexend(11) : .mono(11))
                    .foregroundStyle(Brand.muted)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            Button(action, action: run)
                .buttonStyle(LinkButtonStyle())
                .font(.lexend(12, .medium))
                .disabled(!enabled)
                .help(help ?? "")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}

/// Running: phase, progress bar and counts. Otherwise the last result.
struct BackupStatusRow: View {
    @ObservedObject var backup: BackupController

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: icon).font(.system(size: 11, weight: .semibold)).foregroundStyle(tint)
                Text(title).font(.lexend(12.5, .medium)).lineLimit(1)
                Spacer(minLength: 6)
                if backup.isRunning {
                    Button("Stop") { backup.cancel() }.buttonStyle(LinkButtonStyle()).font(.lexend(11.5, .medium))
                }
            }
            if backup.isRunning {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Rectangle().fill(Brand.secondary)
                        Rectangle().fill(Brand.fill).frame(width: proxy.size.width * backup.progress.fraction)
                    }
                }
                .frame(height: 3)
            }
            if let detail {
                Text(detail)
                    .font(isError ? .lexend(11) : .mono(10.5))
                    .foregroundStyle(isError ? Brand.danger : Brand.muted)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var isError: Bool {
        guard !backup.isRunning, let last = backup.lastOutcome else { return false }
        return last.error != nil || last.incomplete
    }

    private var icon: String {
        if backup.isRunning { return "arrow.up" }
        guard backup.lastOutcome != nil else { return "clock" }
        return isError ? "exclamationmark.triangle" : "checkmark"
    }

    private var tint: Color {
        if backup.isRunning || backup.lastOutcome == nil { return Brand.foreground }
        return isError ? Brand.danger : Brand.green
    }

    private var title: String {
        if backup.isRunning {
            switch backup.phase {
            case .scanning?: return "Looking for changes…"
            case .checking?: return "Checking the Drive…"
            case .deleting?: return "Tidying up…"
            default: return "Backing up…"
            }
        }
        guard let last = backup.lastOutcome else { return "Not backed up yet" }
        let when = Calendar.current.isDateInToday(last.finishedAt)
            ? Formatting.time(last.finishedAt)
            : last.finishedAt.formatted(date: .abbreviated, time: .shortened)
        if last.error != nil { return "Last try " + when }
        return (last.incomplete ? "Partly backed up " : "Backed up ") + when
    }

    private var detail: String? {
        if backup.isRunning {
            let p = backup.progress
            guard backup.phase == .uploading, p.filesTotal > 0 else { return nil }
            return "\(p.filesDone)/\(p.filesTotal) files · \(Formatting.bytes(p.bytesDone)) of \(Formatting.bytes(p.bytesTotal))"
        }
        guard let last = backup.lastOutcome else { return nil }
        if let error = last.error { return error }
        let sent = last.bytes > 0 ? " (\(Formatting.bytes(last.bytes)))" : ""
        var parts = ["\(last.uploaded.formatted()) uploaded\(sent)", "\(last.unchanged.formatted()) unchanged"]
        if last.deleted > 0 { parts.append("\(last.deleted) removed") }
        if last.noRecycleBin {
            parts.append("this share has no Recycle bin, so files deleted here stay on the Drive")
        } else if last.pendingDelete > 0 {
            parts.append("\(last.pendingDelete) deleted here, removed after a week")
        }
        if last.failed > 0 { parts.append("\(last.failed) failed, retried next time") }
        if last.unreadable > 0 {
            let names = last.unreadableSample.joined(separator: ", ")
            parts.append("couldn't read \(last.unreadable.formatted()) (\(names)); allow InFocus in System Settings → Privacy & Security → Full Disk Access")
        }
        if last.conflicts > 0 { parts.append("\(last.conflicts) skipped (a folder is in the way)") }
        return parts.joined(separator: " · ")
    }
}

/// The menu-bar panel's one-line version.
struct BackupMenuRow: View {
    @ObservedObject var drive: DriveController
    @ObservedObject var backup: BackupController

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionLabel(text: "Mac backup")
                Spacer()
                if backup.isConfigured, !backup.isRunning {
                    Button("Back up now") { backup.runNow() }
                        .buttonStyle(LinkButtonStyle())
                        .font(.lexend(12, .medium))
                } else if !backup.isConfigured {
                    Button("Set up…") { Windows.shared.showMain(drive) }
                        .buttonStyle(LinkButtonStyle())
                        .font(.lexend(12, .medium))
                }
            }
            if backup.isConfigured {
                BackupStatusRow(backup: backup)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(Brand.card)
                    .overlay(Rectangle().strokeBorder(Brand.border))
            }
        }
    }
}
