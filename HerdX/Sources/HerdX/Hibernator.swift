import AppKit

/// Ends a quiet workspace's processes, keeping enough of it to put back.
///
/// Owns the records as well as the doing of it, because the sidebar has to draw
/// them and only one thing should decide what the file says.
///
/// The order is the design: everything is asked first, the record is written
/// second, and the workspace is closed last. Closing first and writing after
/// would lose the pointer to a conversation whenever the write failed, and that
/// conversation is then unreachable by any means.
///
/// Every request goes over `LocalAPI` rather than the endpoint. Most of what
/// this needs is outside the client shell's allow-list, and the ones that are
/// not — `workspace.close` — go the same way so that one failure can be read
/// the same as another. That is also why nothing here carries a boot id: the
/// API socket answers for the machine it belongs to, and there is only ever one
/// of those.
@MainActor
final class Hibernator {
    private let store: HibernationStore
    private let send: LocalAPI.Sender
    private(set) var records: [Hibernated]
    /// Workspaces with requests out, so a sweep cannot start a second attempt
    /// on top of the first.
    private var inFlight: Set<String> = []
    /// Revivals under way, held so they outlive the call that started them.
    private var revivals: [UUID: Revival] = [:]

    init(store: HibernationStore = .shared, send: @escaping LocalAPI.Sender = LocalAPI.live) {
        self.store = store
        self.send = send
        self.records = store.load()
    }

    /// What has been hibernated on one machine, in sidebar order.
    func records(forEndpoint endpointID: String) -> [Hibernated] {
        records.filter { $0.endpointID == endpointID }.sorted { $0.number < $1.number }
    }

    /// Brings a hibernated workspace back, and forgets it once it is.
    ///
    func revive(
        _ id: UUID, socket: String?,
        then: @escaping (Result<Hibernated, Error>) -> Void
    ) {
        guard let record = records.first(where: { $0.id == id }) else {
            return then(.failure(Revival.Failure(reason: "that workspace is not hibernated")))
        }
        guard revivals[id] == nil else { return }

        let revival = Revival(record: record, socket: socket, send: send) {
            [weak self] result in
            guard let self else { return }
            self.revivals[id] = nil
            switch result {
            case .success:
                // Forgotten only now: until the workspace is actually back, the
                // record is the only way to reach that conversation again.
                self.forget(id)
                then(.success(record))
            case .failure(let error):
                // The record stays, whatever happened to the half-made
                // workspace. Dropping it when that husk could not be closed
                // was the first way round, on the grounds that a hibernated
                // row beside a running workspace is a lie — but the husk holds
                // only the agents that were resumed before the failure, and
                // the record is the only thing that still knows the session
                // ids of the ones that were not. A visible lie can be undone
                // by closing the husk; a forgotten session id cannot.
                then(.failure(error))
            }
        }
        revivals[id] = revival
        revival.start()
    }

    func forget(_ id: UUID) {
        records.removeAll { $0.id == id }
        try? store.save(records)
    }

    /// Ends the workspace, and calls back with what was written down.
    ///
    /// `endpointID` is herdr's own id for the machine rather than its index,
    /// because the record outlives any particular arrangement of the catalog.
    func hibernate(
        workspace: Snapshot.Workspace,
        in snapshot: Snapshot,
        endpointID: String,
        socket: String?,
        then: @escaping (Result<Hibernated, Error>) -> Void
    ) {
        let workspaceID = workspace.workspaceID
        guard !inFlight.contains(workspaceID) else { return }
        inFlight.insert(workspaceID)

        let tabs = snapshot.tabs.filter { $0.workspaceID == workspaceID }
        let tabIDs = Set(tabs.map(\.tabID))
        let panes = snapshot.panes.filter { tabIDs.contains($0.tabID) }

        var reported: [Reply.PaneEntry] = []
        var layouts: [String: Reply.Layout] = [:]
        var processes: [String: Reply.Info] = [:]
        var firstFailure: Error?
        var outstanding = 1 + tabs.count + panes.count
        var settled = false

        func done(_ result: Result<Hibernated, Error>) {
            guard !settled else { return }
            settled = true
            inFlight.remove(workspaceID)
            then(result)
        }

        func arrived() {
            outstanding -= 1
            guard outstanding == 0, !settled else { return }
            if let firstFailure {
                // A question that was refused is not an answer. Acting on a
                // partial reading is how a busy pane goes unnoticed.
                return done(.failure(firstFailure))
            }
            switch HibernationPlan.plan(
                workspace: workspace, tabs: tabs, endpointID: endpointID,
                panes: reported.filter { $0.workspaceID == workspaceID },
                processes: processes, layouts: layouts)
            {
            case .failure(let refusal):
                done(.failure(refusal))
            case .success(let record):
                // One more reading, as late as it can be taken, because
                // everything above it is already out of date by the time the
                // close goes out.
                confirmStillQuiet(
                    workspaceID, matching: reported.filter { $0.workspaceID == workspaceID },
                    socket: socket
                ) { [weak self] refusal in
                    guard let self else { return }
                    if let refusal { return done(.failure(refusal)) }
                    self.write(record, closing: workspaceID, socket: socket, done: done)
                }
            }
        }

        func ask<Result: Decodable>(
            _ command: Command, _ type: Result.Type, _ keep: @escaping (Result) -> Void
        ) {
            send(command, socket) { result in
                MainActor.assumeIsolated {
                    switch result {
                    case .failure(let failure):
                        firstFailure = firstFailure ?? failure
                    case .success(let body):
                        switch Reply.decode(type, from: body) {
                        case .success(let value): keep(value)
                        case .failure(let failure): firstFailure = firstFailure ?? failure
                        }
                    }
                    arrived()
                }
            }
        }

        // The session ref lives on the pane, so one list answers both questions:
        // what is in this workspace, and which of it can be resumed.
        ask(.paneList, Reply.PaneList.self) { reported = $0.panes }
        for tab in tabs {
            ask(.layoutExport(tab.tabID), Reply.LayoutExport.self) {
                layouts[$0.layout.tabID] = $0.layout
            }
        }
        // Every pane, not only the ones without an agent: which is which is in
        // a reply that has not arrived yet, and one extra request is cheaper
        // than sequencing these behind it.
        for pane in panes {
            ask(.paneProcessInfo(pane.paneID), Reply.ProcessInfo.self) {
                processes[$0.processInfo.paneID] = $0.processInfo
            }
        }
    }

    /// Reads the workspace once more, immediately before closing it.
    ///
    /// This narrows the race. It does not close it, and it would be dishonest
    /// to describe it as though it did.
    ///
    /// `workspace.close` takes a workspace id and a group flag and nothing
    /// else — no revision to check, no precondition, and the server refuses
    /// nothing on account of a busy pane. So there is no way to ask for a
    /// close that happens *only if* nothing has changed. The most a client can
    /// do is look as late as possible and give up if anything has; an agent
    /// that starts a turn in the moment between this reply and the close is
    /// still lost, and no amount of rereading fixes that. Closing it properly
    /// needs a conditional close in the protocol.
    ///
    /// What used to happen was worse than a narrow race: the only reading was
    /// the `pane.list` issued alongside the layout and process queries, so the
    /// window was however long all of those took, and it was the *first* of
    /// them to be answered.
    ///
    /// Two things are checked. Whether an agent has started working or become
    /// blocked, which is the case that costs somebody a turn. And whether the
    /// workspace holds different panes than the ones inspected — a tab opened
    /// since the layouts were read is not in the record, so closing it would
    /// throw it away with nothing written down.
    private func confirmStillQuiet(
        _ workspaceID: String, matching inspected: [Reply.PaneEntry], socket: String?,
        then: @escaping (Error?) -> Void
    ) {
        send(.paneList, socket) { result in
            MainActor.assumeIsolated {
                switch result {
                case .failure(let failure):
                    // A question that was refused is not an answer, and this
                    // is the question standing between a quiet workspace and
                    // one being ended mid-turn.
                    then(failure)
                case .success(let body):
                    switch Reply.decode(Reply.PaneList.self, from: body) {
                    case .failure(let failure):
                        then(failure)
                    case .success(let list):
                        let now = list.panes.filter { $0.workspaceID == workspaceID }
                        then(Self.changed(from: inspected, to: now))
                    }
                }
            }
        }
    }

    /// What about the workspace is no longer what it was, or nil when nothing
    /// relevant is.
    ///
    /// Separate and pure so the rule can be tested without a server, like
    /// `HibernationPlan` beside it.
    static func changed(
        from inspected: [Reply.PaneEntry], to now: [Reply.PaneEntry]
    ) -> HibernationPlan.Refusal? {
        if let busy = now.filter(\.holdsAgent).first(where: {
            $0.agentStatus == .working || $0.agentStatus == .blocked
        }) {
            return HibernationPlan.Refusal(
                reason: "\(busy.agentName) started \(busy.agentStatus) while this was being read")
        }
        let before = Set(inspected.map(\.paneID))
        let after = Set(now.map(\.paneID))
        guard before == after else {
            // Either direction is a reason to stop. Something new is not in
            // the record and would be closed unsaved; something gone means the
            // record describes a workspace that no longer exists.
            return HibernationPlan.Refusal(
                reason: "the workspace changed shape while it was being read")
        }
        return nil
    }

    /// What a `workspace.close` reply says about the workspace.
    ///
    /// A refusal and a silence are not the same answer, and the record turns
    /// on the difference. The server answering no means the workspace is still
    /// running, so its record describes something on screen and has to go. No
    /// answer at all means the close may well have happened — herdr closes the
    /// workspace before it encodes the reply — so removing the record then can
    /// drop the only pointer to conversations that are already gone.
    enum CloseOutcome: Equatable {
        case closed
        case refused(String)
        case unknown(String)
    }

    /// Reads one, without deciding anything, so the decision can be tested.
    static func outcome(of result: Result<String, LocalAPI.Failure>) -> CloseOutcome {
        switch result {
        case .failure(let failure):
            return .unknown(failure.reason)
        case .success(let body):
            guard let data = body.data(using: .utf8),
                let envelope = try? JSONDecoder().decode(
                    Reply.Envelope<Reply.Empty>.self, from: data)
            else {
                // Something answered and we could not read it. That is not the
                // server saying no.
                return .unknown("the reply to workspace.close could not be read")
            }
            if let error = envelope.error { return .refused(error.text) }
            guard envelope.result != nil else {
                return .unknown("the reply to workspace.close carried no result")
            }
            return .closed
        }
    }

    /// Writes the record, then closes the workspace.
    ///
    /// The record goes first and is taken back out if the close is refused: a
    /// row for a workspace that is still running is a confusing but harmless
    /// mistake, while a closed workspace nothing has a pointer to is a
    /// conversation nobody can reach again.
    func write(
        _ record: Hibernated, closing workspaceID: String, socket: String?,
        done: @escaping (Result<Hibernated, Error>) -> Void
    ) {
        records.append(record)
        do {
            try store.save(records)
        } catch {
            records.removeAll { $0.id == record.id }
            return done(.failure(error))
        }

        send(.closeWorkspace(workspaceID), socket) { [weak self] result in
            MainActor.assumeIsolated {
                guard let self else { return }
                switch Self.outcome(of: result) {
                case .closed:
                    done(.success(record))
                case .refused(let reason):
                    self.records.removeAll { $0.id == record.id }
                    try? self.store.save(self.records)
                    done(.failure(LocalAPI.Failure(reason: reason)))
                case .unknown(let reason):
                    done(
                        .failure(
                            LocalAPI.Failure(
                                reason:
                                    "\(reason) — \(record.label) was written down in case it closed"
                            )))
                }
            }
        }
    }
}
