import SwiftUI
import UIKit

/// Run mode, the Portal's full-screen prompter: the script scrolls past a fixed playhead at a set
/// speed. Pause, faster, slower (then reverse), scroll back or forward; jump to a section or another
/// script; script and cue sizes; mirror for a beam-splitter rig. Always dark, like the web's.
/// A hardware keyboard works too: Space, arrows and Esc.
struct TeleprompterRunView: View {
    let model: TeleprompterModel

    @Environment(\.dismiss) private var dismiss
    @State private var docId: String?
    @State private var playback = TeleprompterPlayback()
    @State private var position: Double = 0
    @State private var contentHeight: Double = 0
    @State private var sectionTops: [String: CGFloat] = [:]
    @State private var activeSection: String?
    @State private var settings = TeleprompterRunSettings.load()
    @State private var showSettings = false
    @FocusState private var focused: Bool

    /// Where the playhead sits below the top bar (the web's 128px).
    private let playheadTop: CGFloat = 128

    private var doc: TeleprompterDoc? {
        model.payload?.docs.first { $0.id == (docId ?? model.selectedId) }
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            stage
            controls
        }
        .background(RunColors.stage.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(.space) { apply(.toggle) }
        .onKeyPress(.upArrow) { apply(.faster) }
        .onKeyPress(.downArrow) { apply(.slower) }
        .onKeyPress(.leftArrow) { apply(.back) }
        .onKeyPress(.rightArrow) { apply(.forward) }
        .onKeyPress(.escape) { dismiss(); return .handled }
        .onAppear {
            focused = true
            UIApplication.shared.isIdleTimerDisabled = true
        }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
        .onChange(of: settings) { _, next in next.save() }
        .task(id: doc?.id) { await scroll() }
        .sheet(isPresented: $showSettings) {
            TeleprompterRunSettingsSheet(settings: $settings, speed: playback.label)
                .presentationDetents([.medium])
        }
    }

    private func apply(_ control: TeleprompterPlayback.Control) -> KeyPress.Result {
        playback = playback.applying(control)
        return .handled
    }

    /// Moves the script every frame by speed × time (a slow frame never jumps more than 48 ms).
    private func scroll() async {
        position = 0
        activeSection = doc?.sections.first?.id
        var last = Date()
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(16))
            let now = Date()
            let seconds = min(now.timeIntervalSince(last), 0.048)
            last = now
            guard !playback.paused, contentHeight > 0 else { continue }
            position = playback.advance(position, seconds: seconds, maxPosition: contentHeight)
            let current = TeleprompterRunLayout.section(at: position, tops: sectionTops, order: doc?.sections.map(\.id) ?? [])
            if current != activeSection { activeSection = current }
        }
    }

    // MARK: Top bar

    private var topBar: some View {
        HStack(spacing: 6) {
            Menu {
                ForEach(model.docs) { entry in
                    Button(entry.title) { docId = entry.id }
                }
            } label: {
                barLabel(doc?.title ?? "Script")
            }
            .accessibilityLabel("Show")
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(RunColors.barMuted).accessibilityHidden(true)
            Menu {
                ForEach(doc?.sections ?? []) { section in
                    Button(TeleprompterScript.displayParts(label: section.label, content: section.content).badge.uppercased()) {
                        jump(to: section.id)
                    }
                }
            } label: {
                barLabel(sectionLabel)
            }
            .accessibilityLabel("Section")
            Spacer(minLength: 4)
            if playback.paused {
                Text("PAUSED")
                    .font(.lexend(11, .medium, relativeTo: .caption2)).tracking(1.2)
                    .foregroundStyle(RunColors.pausedText)
                    .padding(.horizontal, 8).frame(height: 22)
                    .background(RunColors.pausedFill, in: RoundedRectangle(cornerRadius: Brand.tagRadius))
            }
            Text(playback.label).font(.mono(12)).monospacedDigit().foregroundStyle(RunColors.barText)
                .accessibilityLabel("Speed \(playback.label)")
            barButton("textformat.size", label: "Font settings") { showSettings = true }
            barButton("xmark", label: "Exit teleprompter") { dismiss() }
        }
        .padding(.horizontal, 8)
        .frame(height: 48)
        .background(RunColors.bar)
    }

    private var sectionLabel: String {
        guard let section = doc?.sections.first(where: { $0.id == activeSection }) ?? doc?.sections.first else { return "Section" }
        return TeleprompterScript.displayParts(label: section.label, content: section.content).badge.uppercased()
    }

    private func barLabel(_ text: String) -> some View {
        HStack(spacing: 4) {
            Text(text).lineLimit(1)
            Image(systemName: "chevron.up.chevron.down").font(.caption2)
        }
        .font(.lexend(13, .medium, relativeTo: .footnote))
        .foregroundStyle(RunColors.barText)
        .frame(minHeight: 44)
    }

    private func barButton(_ systemImage: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage).frame(width: 44, height: 44).contentShape(Rectangle())
        }
        .foregroundStyle(RunColors.barText)
        .accessibilityLabel(label)
    }

    private func jump(to sectionId: String) {
        activeSection = sectionId
        position = Double(max(0, sectionTops[sectionId] ?? 0))
    }

    // MARK: Stage

    private var stage: some View {
        GeometryReader { geometry in
            let sizes = TeleprompterRunLayout.sizes(width: geometry.size.width, settings: settings)
            ZStack(alignment: .topLeading) {
                script(sizes: sizes)
                    .padding(.leading, 64)
                    .padding(.trailing, 24)
                    .frame(width: geometry.size.width, alignment: .topLeading)
                    .offset(y: playheadTop - position)
                playhead.offset(x: 14, y: playheadTop - 22)
            }
            .scaleEffect(x: settings.mirror ? -1 : 1, y: 1)
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
            .clipped()
            .contentShape(Rectangle())
            .onTapGesture { playback = playback.applying(.toggle) }
        }
    }

    private var playhead: some View {
        Path { path in
            path.move(to: .zero)
            path.addLine(to: CGPoint(x: 34, y: 22))
            path.addLine(to: CGPoint(x: 0, y: 44))
            path.closeSubpath()
        }
        .fill(Color.white)
        .frame(width: 34, height: 44)
        .accessibilityHidden(true)
    }

    private func script(sizes: TeleprompterRunLayout.Sizes) -> some View {
        VStack(alignment: .leading, spacing: 64) {
            ForEach(doc?.sections ?? []) { section in
                VStack(alignment: .leading, spacing: 12) {
                    let lines = TeleprompterScript.displayParts(label: section.label, content: section.content).content
                        .components(separatedBy: "\n")
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        RunLineView(line: RunScriptLine.classify(line), sizes: sizes)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.frame(in: .named("run-script")).minY
                } action: { top in
                    sectionTops[section.id] = top
                }
            }
        }
        .coordinateSpace(.named("run-script"))
        .onGeometryChange(for: Double.self) { Double($0.size.height) } action: { contentHeight = $0 }
    }

    // MARK: Controls

    private var controls: some View {
        HStack(spacing: 8) {
            control("backward.fill", label: "Scroll backward", .back)
            control("minus", label: "Slower", .slower)
            control(playback.paused ? "play.fill" : "pause.fill", label: playback.paused ? "Resume" : "Pause", .toggle)
            control("plus", label: "Faster", .faster)
            control("forward.fill", label: "Scroll forward", .forward)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
        .background(RunColors.bar.ignoresSafeArea(edges: .bottom))
    }

    private func control(_ systemImage: String, label: String, _ action: TeleprompterPlayback.Control) -> some View {
        Button { playback = playback.applying(action) } label: {
            Image(systemName: systemImage).font(.title3).frame(width: 56, height: 44).contentShape(Rectangle())
        }
        .foregroundStyle(RunColors.barText)
        .accessibilityLabel(label)
    }
}

/// One script line as run mode draws it: cues in a yellow box, camera calls in capitals, spoken
/// copy large with [RED]/[YELLOW] runs.
private struct RunLineView: View {
    let line: RunScriptLine
    let sizes: TeleprompterRunLayout.Sizes

    var body: some View {
        switch line {
        case .gap:
            Color.clear.frame(height: 32)
        case .camera(let text):
            Text(text).font(.custom("Lexend", fixedSize: sizes.body)).foregroundStyle(RunColors.text)
        case .cue(let text, let spoken):
            VStack(alignment: .leading, spacing: 12) {
                Text(text)
                    .font(.custom("Lexend", fixedSize: sizes.cue).weight(.semibold))
                    .foregroundStyle(RunColors.cueText)
                    .padding(.horizontal, sizes.cue * 0.22)
                    .padding(.vertical, sizes.cue * 0.04)
                    .background(RunColors.cueFill)
                if let spoken { spokenText(spoken) }
            }
        case .spoken(let text):
            spokenText(text)
        }
    }

    private func spokenText(_ text: String) -> some View {
        var result = AttributedString()
        for segment in RunScriptLine.segments(text) {
            var part = AttributedString(segment.text)
            switch segment.tone {
            case .red: part.foregroundColor = RunColors.red
            case .yellow: part.foregroundColor = RunColors.yellow
            case .plain: part.foregroundColor = RunColors.text
            }
            result += part
        }
        return Text(result)
            .font(.custom("Lexend", fixedSize: sizes.body))
            .lineSpacing(sizes.body * 0.12)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Run mode's fixed palette (the web's literal hexes: it stays dark in Light appearance).
private enum RunColors {
    static let stage = Color(hex: 0x0F110F)
    static let text = Color(hex: 0xECEFEA)
    static let bar = Color(hex: 0x1A1D1A)
    static let barText = Color(hex: 0xDCE2DE)
    static let barMuted = Color(hex: 0x6B736E)
    static let cueFill = Color(hex: 0xFFF200)
    static let cueText = Color(hex: 0xFF0000)
    static let red = Color(hex: 0xEF4444)
    static let yellow = Color(hex: 0xFACC15)
    static let pausedFill = Color(hex: 0xF2A516)
    static let pausedText = Color(hex: 0x4A2F00)
}

/// Script and cue sizes and the mirror switch, kept on this iPhone like the web keeps them per browser.
struct TeleprompterRunSettings: Codable, Equatable {
    static let key = "teleprompter-run-mode-settings"
    static let bodyRange: ClosedRange<Double> = 0.55...1.3
    static let cueRange: ClosedRange<Double> = 0.7...1.4

    var bodyScale = 1.0
    var cueScale = 1.0
    var mirror = false

    static func load(_ defaults: UserDefaults = .standard) -> TeleprompterRunSettings {
        guard let data = defaults.data(forKey: key),
              let saved = try? JSONDecoder().decode(TeleprompterRunSettings.self, from: data) else { return .init() }
        return TeleprompterRunSettings(bodyScale: saved.bodyScale.clamped(to: bodyRange),
                                       cueScale: saved.cueScale.clamped(to: cueRange), mirror: saved.mirror)
    }

    func save(_ defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.key) }
    }
}

/// Run mode's measurements, from the web's CSS clamps (rem → 16 pt).
enum TeleprompterRunLayout {
    struct Sizes: Equatable {
        let body: CGFloat
        let cue: CGFloat
    }

    /// Spoken text: clamp(2.5rem, 5.4vw, 6.2rem); cues: clamp(2.35rem, 5.1vw, 5.8rem); each times its scale.
    static func sizes(width: CGFloat, settings: TeleprompterRunSettings) -> Sizes {
        func clamp(_ min: CGFloat, _ vw: CGFloat, _ max: CGFloat, _ scale: Double) -> CGFloat {
            let scale = CGFloat(scale)
            return Swift.min(Swift.max(min * 16 * scale, width * vw / 100 * scale), max * 16 * scale)
        }
        return Sizes(body: clamp(2.5, 5.4, 6.2, settings.bodyScale), cue: clamp(2.35, 5.1, 5.8, settings.cueScale))
    }

    /// The section under the playhead: the last one whose top is within 12 pt of the position.
    static func section(at position: Double, tops: [String: CGFloat], order: [String]) -> String? {
        let sorted = order.compactMap { id in tops[id].map { (id, Double($0)) } }.sorted { $0.1 < $1.1 }
        var current = sorted.first?.0 ?? order.first
        for (id, top) in sorted where top <= position + 12 { current = id }
        return current
    }
}

/// Font settings: script and cue size, mirror, and the keys.
private struct TeleprompterRunSettingsSheet: View {
    @Binding var settings: TeleprompterRunSettings
    let speed: String

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    slider("Script size", value: $settings.bodyScale, range: TeleprompterRunSettings.bodyRange)
                    slider("Cue size", value: $settings.cueScale, range: TeleprompterRunSettings.cueRange)
                    Toggle("Mirror", isOn: $settings.mirror)
                        .frame(minHeight: 44)
                }
                Section("Keyboard") {
                    LabeledContent("Space", value: "Pause / resume")
                    LabeledContent("↑", value: "Faster")
                    LabeledContent("↓", value: "Slower, then reverse")
                    LabeledContent("← →", value: "Scroll back / forward")
                    LabeledContent("Speed", value: "\(speed) pt/s")
                }
            }
            .font(.bodyText)
            .navigationTitle("Font settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Reset") { settings = TeleprompterRunSettings(mirror: settings.mirror) }
                }
            }
        }
    }

    private func slider(_ label: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                Spacer()
                Text("\(Int((value.wrappedValue * 100).rounded()))%").font(.mono(13)).monospacedDigit()
            }
            Slider(value: value, in: range, step: 0.05).tint(Brand.green).accessibilityLabel(label)
        }
    }
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double { Swift.min(Swift.max(self, range.lowerBound), range.upperBound) }
}
