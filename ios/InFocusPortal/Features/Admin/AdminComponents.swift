import SwiftUI

extension View {
    /// "Couldn't do that" with the Portal's words, for a failed action on an Admin or tools screen.
    func actionErrorAlert(_ message: Binding<String?>) -> some View {
        alert("Couldn't do that", isPresented: Binding(get: { message.wrappedValue != nil },
                                                       set: { if !$0 { message.wrappedValue = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(message.wrappedValue ?? "")
        }
    }

    /// The list look every More screen shares.
    func toolsList() -> some View {
        font(.bodyText)
            .scrollContentBackground(.hidden)
            .brandBackground()
    }
}

/// "Not available": a 403 (or the sample app) reads as a plain empty state, never an error screen.
struct NotAvailableView: View {
    var title = "Not available"
    let message: String

    var body: some View {
        ScrollView {
            EmptyStateView(title: title, message: message)
        }
        .brandBackground()
    }
}

/// Name over a quiet second line, with a spinner while something runs on the row.
struct PersonLine: View {
    let title: String
    var detail: String?
    var busy = false

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).foregroundStyle(Brand.foreground)
                if let detail, !detail.isEmpty, detail != title {
                    Text(detail).font(.small).foregroundStyle(Brand.muted)
                }
            }
            Spacer(minLength: 8)
            if busy { ProgressView() }
        }
        .frame(minHeight: 44)
        .accessibilityElement(children: .combine)
    }
}

/// A number with its label, for the totals grid (Geist Mono for the figure).
struct StatTile: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Eyebrow(label, color: Brand.muted, size: 11)
            Text(value)
                .font(.mono(20, .medium, relativeTo: .title3))
                .monospacedDigit()
                .foregroundStyle(Brand.foreground)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(padding: 12)
        .accessibilityElement(children: .combine)
    }
}

/// Load state for screens that only some roles may open: a 403 becomes `.notAvailable`.
enum ToolLoad {
    /// Runs `fetch`; `forbidden` carries the words for a 403 or the sample app.
    @MainActor
    static func run<T: Sendable>(_ state: Binding<Loadable<T>>, notAvailable: Binding<Bool>,
                                 _ fetch: () async throws -> T) async {
        if state.wrappedValue.value == nil { state.wrappedValue = .loading }
        do {
            state.wrappedValue = .loaded(try await fetch())
            notAvailable.wrappedValue = false
        } catch PortalError.forbidden, PortalError.sampleApp {
            notAvailable.wrappedValue = true
        } catch {
            if state.wrappedValue.value == nil { state.wrappedValue = .failed(Loadable<T>.message(for: error)) }
        }
    }
}
