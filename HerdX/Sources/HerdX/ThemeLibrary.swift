import AppKit

/// The themes on this Mac, and a way to fetch more.
///
/// kitty's theme collection is a few hundred `.conf` files in one repository,
/// which is a far better source than a list written out here: it is maintained
/// by other people and already contains everything anyone asks for by name.
enum ThemeLibrary {
    /// Where fetched themes are kept.
    ///
    /// Application Support rather than the app bundle: a bundle is replaced on
    /// every build, and themes someone chose to fetch should outlive that.
    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSHomeDirectory())
        return base.appendingPathComponent("HerdX/themes", isDirectory: true)
    }

    /// One downloadable archive rather than a few hundred requests.
    static let source = URL(
        string: "https://codeload.github.com/kovidgoyal/kitty-themes/tar.gz/refs/heads/master")!

    struct Entry {
        let name: String
        let url: URL
    }

    /// Every theme fetched so far, by name.
    static func installed() -> [Entry] {
        let contents =
            (try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil)) ?? []
        return
            contents
            .filter { $0.pathExtension == "conf" }
            .map { Entry(name: $0.deletingPathExtension().lastPathComponent, url: $0) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func theme(at url: URL) -> Theme? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return Theme(kittyConfiguration: text)
    }

    /// Fetches the collection, replacing whatever was there.
    ///
    /// Reports how many arrived, or why none did. Everything lands in a
    /// temporary directory first and only the `.conf` files are kept, so an
    /// archive carrying anything else leaves nothing behind.
    static func fetch(completion: @escaping @Sendable (Result<Int, Failure>) -> Void) {
        let task = URLSession.shared.downloadTask(with: source) { location, response, error in
            let finish = { (result: Result<Int, Failure>) in
                DispatchQueue.main.async { completion(result) }
            }
            guard error == nil else {
                finish(.failure(Failure(error?.localizedDescription ?? "the download failed")))
                return
            }
            guard let location,
                (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? false
            else {
                finish(.failure(Failure("the theme collection could not be downloaded")))
                return
            }
            do {
                finish(.success(try install(archive: location)))
            } catch let failure as Failure {
                finish(.failure(failure))
            } catch {
                finish(.failure(Failure(error.localizedDescription)))
            }
        }
        task.resume()
    }

    private static func install(archive: URL) throws -> Int {
        let manager = FileManager.default
        let scratch = manager.temporaryDirectory
            .appendingPathComponent("herdx-themes-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: scratch) }

        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = ["-xzf", archive.path, "-C", scratch.path]
        try tar.run()
        tar.waitUntilExit()
        guard tar.terminationStatus == 0 else {
            throw Failure("the theme collection could not be unpacked")
        }

        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        var installed = 0
        guard
            let walk = manager.enumerator(at: scratch, includingPropertiesForKeys: nil)
        else { throw Failure("the theme collection was empty") }

        for case let file as URL in walk where file.pathExtension == "conf" {
            // Only files that actually parse: the archive also carries examples
            // and fragments, and a name in the list that cannot be applied is
            // worse than one that is not there.
            guard let text = try? String(contentsOf: file, encoding: .utf8),
                Theme(kittyConfiguration: text) != nil
            else { continue }
            let destination = directory.appendingPathComponent(file.lastPathComponent)
            try? manager.removeItem(at: destination)
            try manager.copyItem(at: file, to: destination)
            installed += 1
        }
        guard installed > 0 else { throw Failure("no themes were found in the download") }
        return installed
    }

    struct Failure: LocalizedError, Sendable {
        let reason: String
        init(_ reason: String) { self.reason = reason }
        var errorDescription: String? { reason }
    }
}
