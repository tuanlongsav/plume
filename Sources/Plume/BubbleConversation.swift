import AppKit

// MARK: - Avatar cache

/// Decoded avatars, keyed by URL. Bounded, and main-thread only.
enum AvatarCache {
    private static var images: [URL: NSImage] = [:]
    private static var order: [URL] = []
    private static let limit = 96

    static func image(for url: URL) -> NSImage? { images[url] }

    static func store(_ image: NSImage, for url: URL) {
        if images[url] == nil {
            order.append(url)
            while order.count > limit { images.removeValue(forKey: order.removeFirst()) }
        }
        images[url] = image
    }

    /// Fetch once, then serve from memory. `done` always runs on the main thread.
    static func load(_ url: URL, done: @escaping (NSImage) -> Void) {
        if let cached = image(for: url) { done(cached); return }
        URLSession.shared.dataTask(with: url) { data, _, _ in
            guard let data, let image = NSImage(data: data) else { return }
            DispatchQueue.main.async {
                store(image, for: url)
                done(image)
            }
        }.resume()
    }
}

// MARK: - Model

/// One conversation the bubbles can represent. Built from an on-demand snapshot
/// of Messenger's list — deliberately no message text, only what a bubble needs.
struct BubbleConversation {
    let url: URL
    let name: String
    let avatar: URL?
    let unread: Bool
    let preview: String
    let time: String

    /// Compare conversations by this, not by `url`: the same thread can be
    /// listed under `/t/` and open under `/e2ee/t/`.
    var id: String { ThreadURL.id(from: url) ?? url.absoluteString }

    /// Shown until (or instead of) the avatar image loads.
    var initials: String {
        let parts = name.split(separator: " ").prefix(2)
        let letters = parts.compactMap { $0.first.map(String.init) }
        return letters.isEmpty ? "?" : letters.joined().uppercased()
    }

    /// Hand-written, because Swift's synthesised `Decodable` ignores stored
    /// property defaults: a single absent key threw, `fetchConversations`
    /// swallowed the error and returned nothing, and the whole bubble feature
    /// went quiet. Every field a future Messenger change might drop is optional
    /// here.
    struct Raw: Decodable {
        let href: String
        let name: String
        let avatar: String
        let unread: Bool
        let preview: String
        let time: String

        init(from decoder: Decoder) throws {
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

    /// A thread the chain has no head for — enough to put it in the card.
    init(thread: URL) {
        url = thread
        name = "Messenger"
        avatar = nil
        unread = false
        preview = ""
        time = ""
    }

    init?(raw: Raw) {
        guard let thread = ThreadURL.canonical(from: URL(string: raw.href)) else { return nil }
        url = thread
        name = raw.name.isEmpty ? "Messenger" : raw.name
        avatar = raw.avatar.isEmpty ? nil : URL(string: raw.avatar)
        unread = raw.unread
        preview = raw.preview
        time = raw.time
    }
}
