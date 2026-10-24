import SwiftUI

/// Session acquisition happens in a task, never as a side effect of rendering a
/// navigation destination. The route remains project-ID based on every surface.
struct ProjectEditorDestination: View {
    @Environment(ProjectsModel.self) private var model
    let projectID: UUID
    var renameOnOpen = false
    @State private var session: EditorSession?
    var body: some View {
        Group {
            if let session { ProjectDetailView(session: session, sessions: model.editors, renameOnOpen: renameOnOpen) }
            else { ProgressView("Opening project…").frame(maxWidth: .infinity, maxHeight: .infinity).themedSurface() }
        }
        .task {
            if session == nil { session = model.editors.session(for: projectID) }
        }
    }
}
