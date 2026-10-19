import PencilKit
import SwiftUI

/// Settings → Signature: draw with a finger or Apple Pencil, then save it as the
/// Portal stores it (a trimmed PNG, dark ink on transparent), or remove it.
struct SignatureScreen: View {
    let initial: String?
    let changed: (String?) -> Void

    @Environment(\.portalClient) private var client
    @State private var saved: String?
    @State private var drawing = PKDrawing()
    @State private var busy = false
    @State private var confirmingRemove = false
    @State private var message: (text: String, error: Bool)?

    init(initial: String?, changed: @escaping (String?) -> Void) {
        self.initial = initial
        self.changed = changed
        _saved = State(initialValue: initial)
    }

    private var service: SettingsService { SettingsService(client: client) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let png = SignatureInfo.pngData(saved), let image = UIImage(data: png) {
                    VStack(alignment: .leading, spacing: 8) {
                        SectionHeader(title: "Saved signature")
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(maxHeight: 120)
                            .padding(12)
                            .frame(maxWidth: .infinity)
                            .background(Color.white, in: RoundedRectangle(cornerRadius: Brand.radius))
                            .accessibilityLabel("Your saved signature")
                    }
                    .card()
                }
                VStack(alignment: .leading, spacing: 8) {
                    SectionHeader(title: saved == nil ? "Draw your signature" : "Draw a new one",
                                  actionTitle: drawing.strokes.isEmpty ? nil : "Clear",
                                  action: drawing.strokes.isEmpty ? nil : { drawing = PKDrawing() })
                    SignaturePad(drawing: $drawing)
                        .frame(height: 200)
                        .background(Color.white, in: RoundedRectangle(cornerRadius: Brand.radius))
                        .overlay(RoundedRectangle(cornerRadius: Brand.radius).strokeBorder(Brand.control))
                        .accessibilityLabel("Signature pad")
                    Button(busy ? "Saving…" : "Save signature") { Task { await save() } }
                        .buttonStyle(.brandPrimary)
                        .disabled(drawing.strokes.isEmpty || busy)
                    if saved != nil {
                        Button("Remove signature") { confirmingRemove = true }
                            .buttonStyle(QuietDestructiveButtonStyle())
                            .disabled(busy)
                    }
                    if let message {
                        Text(message.text).font(.small).foregroundStyle(message.error ? Brand.danger : Brand.green)
                    }
                }
                .card()
            }
            .padding(Brand.gutter)
        }
        .brandBackground()
        .navigationTitle("Signature")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Remove your signature?", isPresented: $confirmingRemove, titleVisibility: .visible) {
            Button("Remove", role: .destructive) { Task { await remove() } }
        } message: {
            Text("Certificates show a blank line for you until you draw a new one.")
        }
    }

    private func save() async {
        guard let dataURL = SignaturePad.export(drawing) else {
            message = ("That signature is too large. Clear it and draw it again.", true)
            return
        }
        busy = true
        defer { busy = false }
        do {
            let result = try await service.saveSignature(dataURL)
            saved = result.signature
            drawing = PKDrawing()
            changed(result.signature)
            message = ("Saved.", false)
        } catch {
            message = (Loadable<Int>.message(for: error), true)
        }
    }

    private func remove() async {
        busy = true
        defer { busy = false }
        do {
            try await service.deleteSignature()
            saved = nil
            changed(nil)
            message = ("Removed.", false)
        } catch {
            message = (Loadable<Int>.message(for: error), true)
        }
    }
}

/// A PencilKit canvas with a black pen, finger drawing on, always on white.
struct SignaturePad: UIViewRepresentable {
    @Binding var drawing: PKDrawing

    func makeUIView(context: Context) -> PKCanvasView {
        let canvas = PKCanvasView()
        canvas.drawingPolicy = .anyInput
        canvas.tool = PKInkingTool(.pen, color: .black, width: 4)
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.overrideUserInterfaceStyle = .light // ink stays dark on the white pad
        canvas.delegate = context.coordinator
        canvas.drawing = drawing
        return canvas
    }

    func updateUIView(_ canvas: PKCanvasView, context: Context) {
        if canvas.drawing != drawing { canvas.drawing = drawing }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, PKCanvasViewDelegate {
        let parent: SignaturePad
        init(_ parent: SignaturePad) { self.parent = parent }

        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            parent.drawing = canvasView.drawing
        }
    }

    /// The strokes, trimmed to their bounds at 2x, as the PNG data URL the Portal takes.
    static func export(_ drawing: PKDrawing) -> String? {
        guard !drawing.strokes.isEmpty else { return nil }
        let bounds = drawing.bounds.insetBy(dx: -4, dy: -4)
        var image = UIImage()
        UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
            image = drawing.image(from: bounds, scale: 2)
        }
        guard let png = image.pngData() else { return nil }
        return SignatureInfo.dataURL(png: png)
    }
}
