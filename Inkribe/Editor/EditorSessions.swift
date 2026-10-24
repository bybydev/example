import Foundation
import Observation

/// Unsaved project edits survive a completed native pop, including a failed disk save.
/// All routes for the same project share its writer/history rather than forking.
@MainActor
@Observable
final class EditorSessions {
    private let access: ProAccess
    private var sessions: [UUID: EditorSession] = [:]
    private var owners: [UUID: Set<UUID>] = [:]

    init(access: ProAccess) { self.access = access }

    func session(for id: UUID) -> EditorSession {
        // Keep the last clean editor for cancelled/repeated transitions; prune
        // idle clean state when another project is opened. Dirty work never ages out.
        let unused = sessions.keys.filter { $0 != id && owners[$0]?.isEmpty != false && !needsAttention(sessions[$0]!) }
        for key in unused {
            sessions.removeValue(forKey: key)?.stop()
            owners.removeValue(forKey: key)
        }
        if let session = sessions[id] { return session }
        let session = EditorSession(projectID: id, access: access)
        sessions[id] = session
        return session
    }

    func attach(_ session: EditorSession, owner: UUID) {
        sessions[session.projectID] = session
        owners[session.projectID, default: []].insert(owner)
    }

    func detach(_ session: EditorSession, owner: UUID) {
        owners[session.projectID]?.remove(owner)
        session.pause()
        guard owners[session.projectID]?.isEmpty != false else { return }
        session.stop()
        // Unstructured and strongly retained: navigation task cancellation must
        // not cancel the latest save or deallocate an unsaved editor session.
        Task { await session.flush() }
    }

    var pending: [EditorSession] {
        sessions.values.filter { needsAttention($0) }.sorted { $0.projectID.uuidString < $1.projectID.uuidString }
    }
    func hasPending(_ id: UUID) -> Bool { sessions[id].map { needsAttention($0) } ?? false }
    func flushAll() async {
        let current = Array(sessions.values)
        for session in current { session.pause(); await session.flush() }
    }
    private func needsAttention(_ session: EditorSession) -> Bool {
        session.hasPendingChanges || session.isSaving
    }
}
