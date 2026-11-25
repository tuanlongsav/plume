import AppKit

/// Decoded avatars, keyed by URL. Bounded, and main-thread only.
public enum AvatarCache {
    private static var images: [URL: NSImage] = [:]
    private static var order: [URL] = []
    private static let limit = 96

    public static func image(for url: URL) -> NSImage? { images[url] }

    public static func store(_ image: NSImage, for url: URL) {
        if images[url] == nil {
            order.append(url)
            while order.count > limit { images.removeValue(forKey: order.removeFirst()) }
        }
        images[url] = image
    }

    /// Fetch once, then serve from memory. `done` always runs on the main thread.
    public static func load(_ url: URL, done: @escaping (NSImage) -> Void) {
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
