import Foundation

public extension Notification.Name {
    /// Posted by the main web view whenever the dock badge changes.
    static let plumeUnreadChanged = Notification.Name("plume.unreadChanged")
}

/// Typed payload helpers for `.plumeUnreadChanged`.
public enum PlumeUnreadNotification {
    public static let countKey = "count"

    public static func post(count: Int) {
        NotificationCenter.default.post(
            name: .plumeUnreadChanged,
            object: nil,
            userInfo: [countKey: count]
        )
    }

    public static func count(from notification: Notification) -> Int {
        (notification.userInfo?[countKey] as? Int) ?? 0
    }
}
