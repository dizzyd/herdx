import AppKit

/// Whether a newer HerdX has been published.
///
/// Asked once a day at most, and only at launch. There is no updater here and
/// no background poller: the app has one job at startup, which is to find out
/// whether the person running it is a version behind, and telling them twice
/// in an afternoon because they restarted twice is how a helpful notice turns
/// into something people learn to dismiss without reading.
enum Updates {
    /// GitHub's idea of the newest release, which excludes prereleases and
    /// drafts — so anything this returns is something a person could install.
    private static let latest = URL(
        string: "https://api.github.com/repos/dizzyd/herdx/releases/latest")!

    /// Not in `Preferences`, which is the user's settings: when this app last
    /// asked GitHub a question is not a setting, and it has no business in a
    /// struct that is written back every time a colour changes.
    private static let lastCheckKey = "lastUpdateCheck"

    struct Release {
        let version: String
        let page: URL
    }

    /// What this build calls itself, or nil when it is not in a bundle.
    ///
    /// Nil is the ordinary state of a `swift build` run, and there is nothing
    /// to compare against then — an unbundled binary has no version at all, so
    /// every release would look newer than it.
    static var runningVersion: String? {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
    }

    static var lastChecked: Date? {
        UserDefaults.standard.object(forKey: lastCheckKey) as? Date
    }

    static func noteChecked(_ when: Date = Date()) {
        UserDefaults.standard.set(when, forKey: lastCheckKey)
    }

    /// Dev affordance: `HERDX_UPDATE_CHECK=1` asks now, whatever the day says.
    static var forced: Bool {
        ProcessInfo.processInfo.environment["HERDX_UPDATE_CHECK"] != nil
    }

    /// Whether a day has gone by.
    ///
    /// A day's worth of seconds rather than a calendar day, so a restart at
    /// half past midnight is not treated as a new day's first launch. A last
    /// check in the future is a clock that has been put back, and waiting for
    /// it to come round again could be months — so that counts as due.
    static func isDue(lastChecked: Date?, now: Date = Date()) -> Bool {
        guard let lastChecked else { return true }
        if lastChecked > now { return true }
        return now.timeIntervalSince(lastChecked) >= 24 * 60 * 60
    }

    /// Whether `candidate` is a later version than `current`.
    ///
    /// Compared as numbers per component, because as text "1.10.0" sorts before
    /// "1.9.0" and the tenth release of a series would go unannounced.
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        guard let new = components(candidate), let old = components(current) else { return false }
        for index in 0..<max(new.count, old.count) {
            let left = index < new.count ? new[index] : 0
            let right = index < old.count ? old[index] : 0
            if left != right { return left > right }
        }
        return false
    }

    /// `v1.2.3` and `1.2.3` alike, as numbers. Nil when it is not a version at
    /// all, which is read as "no newer release": a tag nobody can parse is not
    /// grounds for telling someone to go and download something.
    private static func components(_ version: String) -> [Int]? {
        let trimmed = version.hasPrefix("v") ? String(version.dropFirst()) : version
        let parts = trimmed.split(separator: ".")
        guard !parts.isEmpty else { return nil }
        var out: [Int] = []
        for part in parts {
            // The digits at the front and nothing after them: a `1.3.0-rc.1`
            // compares as 1.3.0, which is the only part of it that is a number.
            guard let value = Int(part.prefix(while: \.isNumber)) else { return nil }
            out.append(value)
        }
        return out
    }

    /// Asks GitHub, and says nothing at all if it cannot.
    ///
    /// Every failure is silent on purpose. A version check that interrupts to
    /// report that it could not reach the network is worse than one that did
    /// not happen: the person did not ask for it, and there is nothing they
    /// were trying to do that has failed.
    static func fetchLatest(completion: @escaping @Sendable (Release?) -> Void) {
        var request = URLRequest(url: latest)
        request.timeoutInterval = 10
        // GitHub refuses an API request that does not say who is asking.
        request.setValue("HerdX/\(runningVersion ?? "dev")", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        let task = URLSession.shared.dataTask(with: request) { data, response, _ in
            let finish = { (release: Release?) in
                DispatchQueue.main.async { completion(release) }
            }
            struct Payload: Decodable {
                let tagName: String
                let htmlURL: String

                private enum CodingKeys: String, CodingKey {
                    case tagName = "tag_name"
                    case htmlURL = "html_url"
                }
            }
            guard let data,
                (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? false,
                let payload = try? JSONDecoder().decode(Payload.self, from: data),
                let page = URL(string: payload.htmlURL)
            else {
                finish(nil)
                return
            }
            finish(Release(version: payload.tagName, page: page))
        }
        task.resume()
    }
}
