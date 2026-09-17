import AppKit
import CHerdrCore
import UserNotifications

/// A discrete thing the server reported, decoded from the core's queue.
///
/// herdr sends *semantic* events and leaves presentation to each client, so the
/// mapping from "an agent needs attention" to a macOS notification lives here
/// rather than in the protocol.
enum ServerEvent: Decodable {
    case notification(Notification)
    case clipboard(String)
    case windowTitle(String?)
    case bell(Int)
    case error(String)
    case response(requestID: String, body: String)

    struct Notification: Decodable {
        enum Kind: String, Decodable {
            case needsAttention = "needs_attention"
            case finished
            case updateInstalled = "update_installed"
            case custom

            init(from decoder: Decoder) throws {
                let raw = try decoder.singleValueContainer().decode(String.self)
                self = Kind(rawValue: raw) ?? .custom
            }
        }

        let kind: Kind
        let title: String
        let body: String?
        let agent: String?
        let paneID: String?

        enum CodingKeys: String, CodingKey {
            case kind, title, body, agent
            case paneID = "pane_id"
        }
    }

    private enum CodingKeys: String, CodingKey {
        case type, text, title, count, message
        case requestID = "request_id"
        case body
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .type) {
        case "notification":
            self = .notification(try Notification(from: decoder))
        case "clipboard":
            self = .clipboard(try container.decode(String.self, forKey: .text))
        case "window_title":
            self = .windowTitle(try container.decodeIfPresent(String.self, forKey: .title))
        case "bell":
            self = .bell(try container.decode(Int.self, forKey: .count))
        case "response":
            self = .response(
                requestID: try container.decode(String.self, forKey: .requestID),
                body: try container.decode(String.self, forKey: .body))
        default:
            self = .error(try container.decodeIfPresent(String.self, forKey: .message) ?? "")
        }
    }
}

/// Presents server events using the platform's own facilities.
@MainActor
final class EventPresenter {
    private var notificationsAuthorized = false

    /// `UNUserNotificationCenter` raises rather than returning an error when the
    /// process has no bundle, so running the executable outside HerdX.app (as
    /// `swift run` does) must not reach it at all.
    private var notificationsAvailable: Bool {
        Bundle.main.bundleIdentifier != nil
    }

    func requestAuthorization() {
        guard notificationsAvailable else {
            NSLog("herdx: no bundle identifier; notifications disabled")
            return
        }
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { [weak self] granted, _ in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.notificationsAuthorized = granted }
                }
            }
    }

    func present(_ event: ServerEvent, window: NSWindow?) {
        switch event {
        case .notification(let notification):
            post(notification)
        case .clipboard(let text):
            // OSC 52 from a program inside a pane. Writing straight to the
            // pasteboard is the whole point of forwarding it.
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        case .windowTitle:
            // Handled by the app delegate, which knows what it outranks.
            break
        case .bell:
            NSSound.beep()
        case .error(let message):
            NSLog("herdr: %@", message)
        case .response(_, let body):
            handle(response: body)
        }
    }

    /// Replies we care about presenting.
    ///
    /// Selection text has to come back from the server because a selection can
    /// cover scrollback the client never rendered.
    private struct Reply: Decodable {
        struct Result: Decodable {
            let type: String
            let text: String?
        }
        let result: Result?
    }

    private func handle(response body: String) {
        guard let data = body.data(using: .utf8),
            let reply = try? JSONDecoder().decode(Reply.self, from: data),
            let result = reply.result
        else { return }

        if result.type == "pane_selection", let text = result.text, !text.isEmpty {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
    }

    private func post(_ notification: ServerEvent.Notification) {
        guard notificationsAvailable, notificationsAuthorized else { return }

        let content = UNMutableNotificationContent()
        content.title = notification.title
        if let body = notification.body { content.body = body }
        if let agent = notification.agent { content.subtitle = agent }
        // An agent waiting on you is the one thing worth interrupting for.
        content.sound = notification.kind == .needsAttention ? .defaultCritical : .default
        content.interruptionLevel = notification.kind == .needsAttention ? .timeSensitive : .active
        if let paneID = notification.paneID {
            content.userInfo = ["pane_id": paneID]
        }

        UNUserNotificationCenter.current().add(
            UNNotificationRequest(
                identifier: UUID().uuidString, content: content, trigger: nil))
    }
}
