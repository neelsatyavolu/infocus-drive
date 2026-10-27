import SwiftUI

/// The recordings in Drive's `Shows/` folder and its subfolders, while the show can be edited.
/// Ticking a file adds it (on its camera role, else Auto); ticking a folder adds all its finished
/// files. The chosen files' order and roles can be changed underneath.
struct RecordingsCard: View {
    let model: ShowEditModel
    let state: ShowEditState

    @State private var showAll = false
    @State private var openFolders: Set<String> = []

    var body: some View {
        let selected = model.selected
        let chosen = Set(selected.map(\.path))
        VStack(alignment: .leading, spacing: 12) {
            Text("Recordings").headline(.h3)
            EditNote(text: "From the Shows folder on Drive, newest first. This show's recordings are ticked already.")
            if let error = state.recordingsError { EditErrorBanner(message: error) }
            if state.settings.autoStart {
                let note = ShowEditRules.autoStartNote(state.autoStart)
                EditNote(text: note.text, warning: note.warning)
            }
            if state.recordings.isEmpty {
                EditNote(text: "No recordings in the Shows folder on Drive yet.")
            } else {
                VStack(spacing: 0) {
                    ForEach(ShowEditRules.groups(state.recordings), id: \.folder) { group in
                        if let folder = group.folder {
                            folderRows(folder, files: group.files, chosen: chosen)
                        } else {
                            looseRows(group.files, chosen: chosen)
                        }
                    }
                }
                .overlay(RoundedRectangle(cornerRadius: Brand.radius).strokeBorder(Brand.line))
                chosenList(selected)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
        .disabled(model.busy != nil)
    }

    private func update(_ next: [ShowEditSource]) { model.picked = next }

    @ViewBuilder
    private func looseRows(_ files: [ShowEditState.Recording], chosen: Set<String>) -> some View {
        let visible = ShowEditRules.visible(files, chosen: chosen, showAll: showAll)
        ForEach(visible.shown) { recording in
            fileRow(recording, chosen: chosen.contains(recording.path))
        }
        if visible.hidden > 0 || (showAll && files.count > ShowEditRules.recordingsShown) {
            Button(showAll ? "Show fewer" : "Show \(visible.hidden) older") { showAll.toggle() }
                .font(.small).foregroundStyle(Brand.muted)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .padding(.horizontal, 12)
        }
    }

    @ViewBuilder
    private func folderRows(_ folder: String, files: [ShowEditState.Recording], chosen: Set<String>) -> some View {
        let usable = files.filter(\.stable)
        let picked = usable.filter { chosen.contains($0.path) }.count
        let open = openFolders.contains(folder)
        let name = folder.split(separator: "/").last.map(String.init) ?? folder
        HStack(spacing: 10) {
            Button { update(ShowEditRules.toggleFolder(model.selected, files: files)) } label: {
                Image(systemName: picked == 0 ? "square" : picked == usable.count ? "checkmark.square.fill" : "minus.square.fill")
                    .font(.title3)
                    .foregroundStyle(picked == 0 ? Brand.control : Brand.green)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .disabled(usable.isEmpty)
            .accessibilityLabel("All files in \(name)")
            .accessibilityValue(picked == 0 ? "None chosen" : picked == usable.count ? "All chosen" : "Some chosen")
            Button {
                if open { openFolders.remove(folder) } else { openFolders.insert(folder) }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: open ? "chevron.down" : "chevron.right").font(.small)
                    Image(systemName: "folder").foregroundStyle(Brand.muted)
                    Text(name).font(.lexend(15, .medium, relativeTo: .body)).lineLimit(1)
                    Text("\(files.count) \(files.count == 1 ? "file" : "files")").font(.small).foregroundStyle(Brand.muted)
                    Spacer(minLength: 0)
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(open ? "Open" : "Closed")
        }
        .padding(.trailing, 12)
        if open {
            ForEach(files) { recording in
                fileRow(recording, chosen: chosen.contains(recording.path)).padding(.leading, 24)
            }
        }
    }

    private func fileRow(_ recording: ShowEditState.Recording, chosen: Bool) -> some View {
        let note = ShowEditRules.exclusion(recording, in: state.recordings)
        return Button { update(ShowEditRules.toggle(model.selected, path: recording.path)) } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: chosen ? "checkmark.square.fill" : "square")
                    .font(.title3)
                    .foregroundStyle(chosen ? Brand.green : Brand.control)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(recording.name).font(.lexend(15, .medium, relativeTo: .body)).foregroundStyle(Brand.foreground)
                    Text(ShowEditRules.pacific(recording.modifiedAt) + " · " + ShowEditRules.size(recording.size)
                         + (recording.stable ? "" : " · still copying"))
                        .font(.small).foregroundStyle(Brand.muted)
                    if let note { Text(note).font(.small).foregroundStyle(Brand.warning) }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!recording.stable)
        .accessibilityAddTraits(chosen ? .isSelected : [])
    }

    @ViewBuilder
    private func chosenList(_ selected: [ShowEditSource]) -> some View {
        if selected.isEmpty {
            EditNote(text: "Tick the show's recordings above.")
        } else {
            Eyebrow("Chosen, in order (\(selected.count) of \(ShowEditRules.maxSources))", color: Brand.muted)
            ForEach(Array(selected.enumerated()), id: \.element.path) { index, source in
                HStack(spacing: 8) {
                    Text("\(index + 1)").font(.mono(12)).foregroundStyle(Brand.muted).frame(width: 18)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(source.fileName).font(.small).lineLimit(1).truncationMode(.middle)
                        Menu {
                            Picker("Role", selection: Binding(
                                get: { source.role },
                                set: { update(ShowEditRules.setRole(model.selected, path: source.path, role: $0)) }
                            )) {
                                ForEach(ShowEditSource.Role.allCases, id: \.self) { Text($0.label).tag($0) }
                            }
                        } label: {
                            Label(source.role.label, systemImage: "chevron.up.chevron.down")
                                .font(.small).foregroundStyle(Brand.green)
                        }
                        .accessibilityLabel("Role of \(source.fileName): \(source.role.label)")
                    }
                    Spacer(minLength: 0)
                    moveButton("arrow.up", "Move \(source.fileName) earlier", disabled: index == 0) {
                        update(ShowEditRules.move(model.selected, from: index, by: -1))
                    }
                    moveButton("arrow.down", "Move \(source.fileName) later", disabled: index == selected.count - 1) {
                        update(ShowEditRules.move(model.selected, from: index, by: 1))
                    }
                }
            }
            if let problem = ShowEditRules.selectionError(selected) { EditErrorBanner(message: problem) }
        }
    }

    private func moveButton(_ symbol: String, _ label: String, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).frame(width: 44, height: 44) }
            .buttonStyle(.plain)
            .foregroundStyle(disabled ? Brand.control : Brand.foreground)
            .disabled(disabled)
            .accessibilityLabel(label)
    }
}
