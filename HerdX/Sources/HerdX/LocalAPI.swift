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
    struct Failure: Error, Equatable {
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

    /// Which socket this run should talk to.
    ///
    /// The environment outranks the remembered session, exactly as it does when
    /// the session itself is chosen — otherwise a test run pointed at a
    /// throwaway session by `HERDR_CLIENT_SOCKET_PATH` would have its API calls
    /// quietly land on the real one, which is the single thing a dev run must
    /// never do.
    static func socketPath(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        sessionName: String? = nil,
        sessions: () -> [SessionEntry] = SessionCatalog.list
    ) -> String? {
        if let api = environment["HERDR_SOCKET_PATH"], !api.isEmpty { return api }
        if let client = environment["HERDR_CLIENT_SOCKET_PATH"], !client.isEmpty {
            return apiSocket(besideClientSocket: client)
        }
        let listed = sessions()
        if let name = sessionName, let match = listed.first(where: { $0.name == name }) {
            return match.apiSocket
        }
        return listed.first(where: \.isDefault)?.apiSocket ?? listed.first?.apiSocket
    }

    /// Sends one request and calls back on the main thread with the reply body.
    ///
    /// One connection per request: the API socket answers a request and closes,
    /// which a long-lived connection finds out the hard way as a broken pipe on
    /// the second send.
    static func send(
        _ command: Command,
        socket path: String?,
        timeout: TimeInterval = 5,
        then: @escaping (Result<String, Failure>) -> Void
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

        // A server that accepts the connection and then says nothing must not
        // hold this thread for the life of the process.
        var limit = timeval(
            tv_sec: Int(timeout), tv_usec: Int32((timeout - timeout.rounded(.down)) * 1_000_000))
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))

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
