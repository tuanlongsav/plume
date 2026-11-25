import Foundation

/// One conversation the bubbles can represent. Built from an on-demand snapshot
/// of Messenger's list — deliberately no message text, only what a bubble needs.
public struct BubbleConversation: Equatable {
    public let url: URL
    public let name: String
    public let avatar: URL?
    public let unread: Bool
    public let preview: String
    public let time: String

    /// Compare conversations by this, not by `url`: the same thread can be
    /// listed under `/t/` and open under `/e2ee/t/`.
    public var id: String { ThreadURL.id(from: url) ?? url.absoluteString }

    /// Shown until (or instead of) the avatar image loads.
    public var initials: String {
        let parts = name.split(separator: " ").prefix(2)
        let letters = parts.compactMap { $0.first.map(String.init) }
        return letters.isEmpty ? "?" : letters.joined().uppercased()
    }

    /// Hand-written, because Swift's synthesised `Decodable` ignores stored
    /// property defaults: a single absent key threw, `fetchConversations`
    /// swallowed the error and returned nothing, and the whole bubble feature
    /// went quiet. Every field a future Messenger change might drop is optional
    /// here.
    public struct Raw: Decodable {
        public let href: String
        public let name: String
        public let avatar: String
        public let unread: Bool
        public let preview: String
        public let time: String

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            href = try c.decode(String.self, forKey: .href)
            name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? ""
            avatar = (try? c.decodeIfPresent(String.self, forKey: .avatar)) ?? ""
            unread = (try? c.decodeIfPresent(Bool.self, forKey: .unread)) ?? false
            preview = (try? c.decodeIfPresent(String.self, forKey: .preview)) ?? ""
            time = (try? c.decodeIfPresent(String.self, forKey: .time)) ?? ""
        }

        enum CodingKeys: String, CodingKey {
            case href, name, avatar, unread, preview, time
        }
    }

    public init(url: URL, name: String, avatar: URL? = nil,
                unread: Bool = false, preview: String = "", time: String = "") {
        self.url = url
        self.name = name
        self.avatar = avatar
        self.unread = unread
        self.preview = preview
        self.time = time
    }

    /// A thread the chain has no head for — enough to put it in the card.
    public init(thread: URL) {
        url = thread
        name = "Messenger"
        avatar = nil
        unread = false
        preview = ""
        time = ""
    }

    public init?(raw: Raw) {
        guard let thread = ThreadURL.canonical(from: URL(string: raw.href)) else { return nil }
        url = thread
        name = raw.name.isEmpty ? "Messenger" : raw.name
        avatar = raw.avatar.isEmpty ? nil : URL(string: raw.avatar)
        unread = raw.unread
        preview = raw.preview
        time = raw.time
    }
}
