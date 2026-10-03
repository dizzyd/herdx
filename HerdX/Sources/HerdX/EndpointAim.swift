import Foundation

/// The machine an operation is working on, pinned for its whole life.
///
/// Anything that takes more than one request is several requests with a
/// person's decisions between them, and nothing stops the window moving to
/// another machine in the gaps — a sheet or a picker can sit open for as long
/// as you like, and a reply can take as long as `git worktree add` does.
///
/// Workspace ids, tab ids, pane ids and checkout paths are only unique within
/// a server. One carried forward and resolved against whatever is active
/// *now* names somebody else's work, which is how a force-removal confirmed
/// for one machine could delete a different machine's checkout, and how an
/// installer command could be typed into a pane on another machine
/// altogether.
struct EndpointAim: Equatable {
    /// Which session object, by token rather than by reference: holding the
    /// session would keep it alive through the reply being waited on, and a
    /// reply that never comes would keep it alive for good.
    let session: UUID
    let endpoint: Int
    let bootID: String
    /// For saying which machine, when an operation has to be abandoned.
    let label: String

    /// Why a pinned operation may no longer act, or nil when it may.
    ///
    /// Abandoning is the answer rather than redirecting, and rather than
    /// switching the window back: the decision was made about one machine, and
    /// both acting on another and yanking the view to the first are worse than
    /// stopping and saying so.
    ///
    /// A new boot id counts as a different machine: the server restarted, and
    /// the ids being held describe a session that no longer exists.
    func drift(session: UUID?, activeEndpoint: Int, bootID: String?) -> String? {
        guard session == self.session else { return "the connection was rebuilt" }
        guard activeEndpoint == endpoint, bootID == self.bootID else {
            return "\(label) is no longer in front of you"
        }
        return nil
    }
}
