import SwiftUI

/// A fresh identity makes repeated requests for the same project/tool distinct.
struct QueueProjectRoute: Hashable, Identifiable, Sendable {
    let id = UUID()
    let projectID: UUID
    let job: ProcessingJobKey
}

/// Each presentation owner dismisses its own sheet before forwarding a request.
/// The root opens projects; an existing editor reuses itself for its own project.
struct QueueProjectNavigation: Sendable {
    var open: @MainActor @Sendable (QueueProjectRoute) -> Void = { _ in }
    @MainActor func callAsFunction(_ route: QueueProjectRoute) { open(route) }
}

private struct QueueProjectNavigationKey: EnvironmentKey {
    static let defaultValue = QueueProjectNavigation()
}

extension EnvironmentValues {
    var queueProjectNavigation: QueueProjectNavigation {
        get { self[QueueProjectNavigationKey.self] }
        set { self[QueueProjectNavigationKey.self] = newValue }
    }
}

extension ProjectsModel {
    func queueProjectID(for key: ProcessingJobKey) -> UUID? {
        let id = processing.entry(key)?.projectID ??
            (key.kind == .export ? exports.artifacts[key.jobID]?.projectID : nil)
        return allProjects.first { $0.id == id }?.id
    }

    func queueProjectRoute(for key: ProcessingJobKey) -> QueueProjectRoute? {
        guard let projectID = queueProjectID(for: key) else { return nil }
        return QueueProjectRoute(projectID: projectID, job: key)
    }
}

/// Details are optional inspection. Complete their dismissal before asking the
/// enclosing Queue/Export/Storage presentation to hand off to a project.
private struct QueueJobDetailsPresentation: ViewModifier {
    @Environment(ProjectsModel.self) private var model
    @Environment(\.queueProjectNavigation) private var openProject
    @Binding var key: ProcessingJobKey?
    @State private var pendingRoute: QueueProjectRoute?

    func body(content: Content) -> some View {
        content.sheet(item: $key, onDismiss: finishNavigation) { selection in
            NavigationStack {
                ProcessingJobDetail(key: selection)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { key = nil }.disabled(model.exports.hasUserDelivery)
                        }
                    }
            }
            .environment(\.queueProjectNavigation, QueueProjectNavigation { route in
                guard pendingRoute == nil, !model.exports.hasUserDelivery else { return }
                pendingRoute = route
                key = nil
            })
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
            .interactiveDismissDisabled(model.exports.hasUserDelivery)
        }
    }

    private func finishNavigation() {
        guard let route = pendingRoute else { return }
        pendingRoute = nil
        openProject(route)
    }
}

extension View {
    func queueJobDetails(_ key: Binding<ProcessingJobKey?>) -> some View {
        modifier(QueueJobDetailsPresentation(key: key))
    }
}
