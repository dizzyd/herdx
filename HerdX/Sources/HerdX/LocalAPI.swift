import Darwin
import Foundation

/// Talks to the local herdr API socket, for the requests the endpoint will not
/// carry.
///
/// HerdX's ordinary requests go over the *client shell* transport, which serves
/// a fixed allow-list of 37 methods — enough to drive a session, and nothing
/// that reads it. `pane.list`, `pane.process_info`, `layout.export`,
/// `layout.apply` and `agent.start` are all outside it, and a request for one
/// comes back `unsupported_method`. The API socket the herdr CLI uses has the
/// whole surface, and for a session on this Mac it is a file sitting next to
/// the one already connected.
///
/// Local only, and that is not a simplification: a remote machine is reachable
/// through the endpoint alone, so the same feature there needs herdr to widen
/// the list. Going around the endpoint for something local has precedent —
/// `SessionCatalog` runs the herdr binary, `Machines` reads herdr's own catalog
/// file — but this is still a second way to talk to herdr, and worth keeping
/// small.
enum LocalAPI {
    struct Failure: Error, Equatable, Sendable {
        let reason: String
    }

    /// The API socket beside a client socket.
    ///
    /// `default_socket_path` in herdr-core derives one from the other by the
    /// same rule, in the other direction: the two sit under one stem, with the
    /// client's carrying a `-client` suffix.
    static func apiSocket(besideClientSocket path: String) -> String {
        let url = URL(fileURLWithPath: path)
        let stem = url.deletingPathExtension().lastPathComponent
        guard stem.hasSuffix("-client") else { return path }
        return
            url
            .deletingLastPathComponent()
            .appendingPathComponent("\(stem.dropLast("-client".count)).sock")
            .path
    }

    // There is deliberately no second way to choose a session here.
    //
    // There used to be: a `socketPath` that re-derived one from the
    // environment and the saved name. The window had already chosen, by its
    // own rules — `HERDX_SESSION` outranks the saved name there — so the two
    // could disagree, and a run aimed at a throwaway session hibernated the
    // saved one. Workspace ids are only unique within a server, so a matching
    // id closed a live workspace on the developer's own session.
    //
    // The socket now comes from `HerdrSession.apiSocket`: whatever client
    // socket this window actually attached to, turned around by the rule
    // above. That inherits herdr-core's `default_socket_path` precedence
    // instead of restating it, and there is one answer rather than two.

    /// Sends one request and calls back on the main thread with the reply body.
    ///
    /// One connection per request: the API socket answers a request and closes,
    /// which a long-lived connection finds out the hard way as a broken pipe on
    /// the second send.
    ///
    /// Main-actor isolated at both ends: every caller is on the main thread,
    /// and saying so lets the reply closure hop back there without being
    /// `@Sendable` — which the callers' main-thread state could not satisfy.
    /// How a request reaches herdr, so a test can answer one without a socket.
    ///
    /// Hibernation and revival are long sequences whose failure paths decide
    /// whether a conversation stays reachable, and those paths are the ones
    /// worth testing. A real socket cannot be asked to lose a reply.
    typealias Sender = @MainActor (
        Command, String?, @escaping @MainActor (Result<String, Failure>) -> Void
    ) -> Void

    /// The one that talks to the socket.
    @MainActor
    static let live: Sender = { command, path, then in
        send(command, socket: path, then: then)
    }

    @MainActor
    static func send(
        _ command: Command,
        socket path: String?,
        timeout: TimeInterval = 5,
        then: @escaping @MainActor (Result<String, Failure>) -> Void
    ) {
        let id = UUID().uuidString
        guard let json = command.requestJSON(id: id) else {
            return then(.failure(Failure(reason: "could not build \(command.method)")))
        }
        guard let path else {
            return then(.failure(Failure(reason: "no local herdr socket to ask")))
        }
        queue.async {
            let result = exchange(json: json, id: id, path: path, timeout: timeout)
            DispatchQueue.main.async { then(result) }
        }
    }

    /// Off the main thread, because every call here blocks and the main thread
    /// is drawing a terminal sixty times a second.
    private static let queue = DispatchQueue(label: "dev.herdr.herdx.local-api")

    /// The options a request's socket needs before anything is written to it.
    ///
    /// Separate so a test can read them back: one of them is the difference
    /// between a failed request and a dead app, and nothing about the call
    /// site would show it had been dropped.
    static func configure(_ descriptor: Int32, timeout: TimeInterval) {
        // A peer that has gone away turns the next write into SIGPIPE, which
        // by default kills the app — before the `wrote > 0` check below can
        // notice, so the careful failure handling under it never ran. A herdr
        // server stopping between the connect and the send is enough, and the
        // bigger the request the wider the window: `layout.apply` for a large
        // tab is not a few bytes. Measured: without this the process exits on
        // signal 13 with no result at all.
        var refuseSigpipe: Int32 = 1
        setsockopt(
            descriptor, SOL_SOCKET, SO_NOSIGPIPE, &refuseSigpipe,
            socklen_t(MemoryLayout<Int32>.size))

        // A server that accepts the connection and then says nothing must not
        // hold this thread for the life of the process.
        var limit = timeval(
            tv_sec: Int(timeout), tv_usec: Int32((timeout - timeout.rounded(.down)) * 1_000_000))
        setsockopt(
            descriptor, SOL_SOCKET, SO_RCVTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(
            descriptor, SOL_SOCKET, SO_SNDTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))
    }

    private static func exchange(
        json: String, id: String, path: String, timeout: TimeInterval
    ) -> Result<String, Failure> {
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            return .failure(Failure(reason: "could not open a socket"))
        }
        defer { Darwin.close(descriptor) }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard bytes.count < capacity else {
            return .failure(Failure(reason: "socket path is too long: \(path)"))
        }
        withUnsafeMutablePointer(to: &address.sun_path) { field in
            field.withMemoryRebound(to: CChar.self, capacity: capacity) { destination in
                for (offset, byte) in bytes.enumerated() {
                    destination[offset] = CChar(bitPattern: byte)
                }
                destination[bytes.count] = 0
            }
        }

        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                Darwin.connect(descriptor, generic, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            return .failure(Failure(reason: "could not reach \(path)"))
        }

        configure(descriptor, timeout: timeout)

        var outgoing = Array((json + "\n").utf8)
        var sent = 0
        while sent < outgoing.count {
            let wrote = outgoing.withUnsafeBytes { buffer in
                Darwin.send(descriptor, buffer.baseAddress! + sent, outgoing.count - sent, 0)
            }
            guard wrote > 0 else { return .failure(Failure(reason: "could not send the request")) }
            sent += wrote
        }

        // Replies arrive as lines, and anything the server volunteers arrives
        // on the same stream, so the one carrying this request's id is the
        // answer and the rest is not.
        var pending = Data()
        var chunk = [UInt8](repeating: 0, count: 8192)
        while true {
            let read = Darwin.recv(descriptor, &chunk, chunk.count, 0)
            if read < 0 { return .failure(Failure(reason: "\(command(in: json)) timed out")) }
            if read == 0 {
                return .failure(Failure(reason: "the server closed without answering"))
            }
            pending.append(contentsOf: chunk[0..<read])

            while let newline = pending.firstIndex(of: UInt8(ascii: "\n")) {
                let line = pending[pending.startIndex..<newline]
                pending = pending[pending.index(after: newline)...]
                let body = String(decoding: line, as: UTF8.self)
                if replyID(of: body) == id { return .success(body) }
            }
        }
    }

    /// The `id` of a reply, without decoding the rest of it.
    private static func replyID(of body: String) -> String? {
        struct Head: Decodable { let id: String }
        guard let data = body.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(Head.self, from: data).id
    }

    /// The method name out of a request, for saying which one timed out.
    private static func command(in json: String) -> String {
        struct Head: Decodable { let method: String }
        guard let data = json.data(using: .utf8),
            let head = try? JSONDecoder().decode(Head.self, from: data)
        else { return "the request" }
        return head.method
    }
}
