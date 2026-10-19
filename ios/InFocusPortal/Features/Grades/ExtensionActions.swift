import SwiftUI

/// The Approve and Deny sheets plus the "couldn't update" alert, for any
/// screen that shows extension request cards.
struct ExtensionActions: ViewModifier {
    let model: ExtensionsModel
    let service: GradesService
    let badges: BadgeCenter
    @Binding var approving: ExtensionRequest?
    @Binding var denying: ExtensionRequest?
    @Binding var granting: ExtensionRequest?

    func body(content: Content) -> some View {
        content
            .sheet(item: $approving) { request in
                ApproveExtensionSheet(request: request, viewerId: model.state.value?.currentUserId ?? "") { terms in
                    await model.approve(request, terms: terms, service: service, badges: badges)
                }
            }
            .sheet(item: $granting) { request in
                ApproveExtensionSheet(request: request, viewerId: model.state.value?.currentUserId ?? "", grant: true) { terms in
                    await model.approve(request, terms: terms, grant: true, service: service, badges: badges)
                }
            }
            .sheet(item: $denying) { request in
                DenyExtensionSheet(request: request) { reason in
                    await model.deny(request, reason: reason, service: service, badges: badges)
                }
            }
            .alert("Couldn't update the request",
                   isPresented: Binding(get: { model.actionError != nil }, set: { if !$0 { model.actionError = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(model.actionError ?? "")
            }
            .alert("Extension requests",
                   isPresented: Binding(get: { model.notice != nil }, set: { if !$0 { model.notice = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(model.notice ?? "")
            }
    }
}

extension ExtensionRequestCard {
    /// A card wired to `model`: agree/decline run at once, approve/deny open their sheets.
    init(request: ExtensionRequest, payload: ExtensionRequestsPayload, model: ExtensionsModel, service: GradesService,
         badges: BadgeCenter, approving: Binding<ExtensionRequest?>, denying: Binding<ExtensionRequest?>,
         granting: Binding<ExtensionRequest?>) {
        self.init(request: request, viewerId: payload.currentUserId, busy: model.busyRequestId == request.id,
                  canEmail: payload.canGrant,
                  onRespond: { agreed in
                      Task { await model.respond(request, agreed: agreed, service: service, badges: badges) }
                  },
                  onApprove: { approving.wrappedValue = request },
                  onDeny: { denying.wrappedValue = request },
                  onGrant: { granting.wrappedValue = request },
                  onEmail: { Task { await model.emailGroup(request, service: service) } })
    }
}
