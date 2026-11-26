import AppKit
import GhostGridCore
import UserNotifications

/// Ghostty options that Ghostty's own app implements (not libghostty), read
/// from the user's flattened config so ghostgrid can honour them too.
/// Updated on launch and on Reload Configuration.
@MainActor
final class GhosttyOptions {
    static let shared = GhosttyOptions()
    static let didChange = Notification.Name("GhosttyOptionsDidChange")

    private(set) var values = GhosttyConfigValues("")

    /// `mouse-hide-while-typing` (Ghostty default: false).
    var mouseHideWhileTyping: Bool {
        values.bool("mouse-hide-while-typing", default: false)
    }

    /// `unfocused-split-opacity` (Ghostty default 0.7, clamped 0.15...1).
    var unfocusedOpacity: Double {
        min(max(values.double("unfocused-split-opacity", default: 0.7), 0.15), 1)
    }

    func update(from configText: String?) {
        values = GhosttyConfigValues(configText ?? "")
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }
}

/// Desktop notifications from programs in a pane (OSC 9 / OSC 777), which
/// Ghostty's app shows and libghostty only reports.
@MainActor
enum Notifier {
    private static var authorized: Bool?

    static func post(title: String, body: String) {
        if authorized == true {
            deliver(title: title, body: body)
            return
        }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            Task { @MainActor in
                authorized = granted
                if granted { deliver(title: title, body: body) }
            }
        }
    }

    private static func deliver(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title.isEmpty ? "ghostgrid" : title
        content.body = body
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil),
        )
    }
}
