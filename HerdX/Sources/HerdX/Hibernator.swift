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
                write(record, closing: workspaceID, socket: socket, done: done)
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
