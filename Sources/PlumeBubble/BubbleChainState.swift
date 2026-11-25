import CoreGraphics
import Foundation

/// Per-head state in the bubble chain, replacing six parallel arrays so
/// insertions, removals and reorders stay atomic by construction.
public struct BubbleHead<Panel> {
    public let panel: Panel
    /// Nil for the app chip (index 0); canonical conversation id for contacts.
    public let conversationID: String?
    public var centre: CGPoint
    public var velocity: CGPoint
    public var diameter: CGFloat
    public var hoverTarget: CGFloat
    public var born: CFTimeInterval

    public init(panel: Panel,
                conversationID: String?,
                centre: CGPoint,
                velocity: CGPoint = .zero,
                diameter: CGFloat = 0,
                hoverTarget: CGFloat,
                born: CFTimeInterval) {
        self.panel = panel
        self.conversationID = conversationID
        self.centre = centre
        self.velocity = velocity
        self.diameter = diameter
        self.hoverTarget = hoverTarget
        self.born = born
    }
}

/// Ordered collection of bubble heads together with the tracked indices
/// (`anchorIndex`, `lastOpenedIndex`, `hoverFocus`) and `pinnedIDs`.
///
/// Generic over `Panel` so every mutation and index remap can be unit-tested
/// without instantiating AppKit `NSPanel` windows.
public struct BubbleChainStore<Panel> {
    public var heads: [BubbleHead<Panel>] = []
    /// The bubble the chain hangs from — index 0, or whichever one is dragged.
    public var anchorIndex = 0
    /// Index of the bubble the card belongs to, for the fold-away animation.
    public var lastOpenedIndex = 0
    /// Sticky Dock focus — only changes on real pointer motion, with hysteresis.
    public var hoverFocus: Int?
    /// Heads the user opened from the picker. They stay in the chain even
    /// when the thread is older than the recents window (`BubbleChainSync`).
    public var pinnedIDs: Set<String> = []

    public init() {}

    public var count: Int { heads.count }
    public var isEmpty: Bool { heads.isEmpty }
    public var indices: Range<Int> { heads.indices }
    /// Contact heads exclude index 0 (the app chip).
    public var contactCount: Int { max(0, heads.count - 1) }

    public subscript(index: Int) -> BubbleHead<Panel> {
        get { heads[index] }
        set { heads[index] = newValue }
    }

    public func index(forID id: String?) -> Int? {
        heads.firstIndex { $0.conversationID == id }
    }

    /// Insert `head` at `rawIndex` (clamped to `0...count`; nil appends).
    /// When `adjustTrackedIndices` is true and the chain was non-empty, shifts
    /// `anchorIndex`, `lastOpenedIndex` and `hoverFocus` past the insertion.
    @discardableResult
    public mutating func insert(_ head: BubbleHead<Panel>,
                                at rawIndex: Int? = nil,
                                adjustTrackedIndices: Bool = true) -> Int {
        let wasEmpty = heads.isEmpty
        let i = rawIndex.map { min(max($0, 0), heads.count) } ?? heads.count
        heads.insert(head, at: i)
        if adjustTrackedIndices && !wasEmpty {
            if anchorIndex >= i { anchorIndex += 1 }
            if lastOpenedIndex >= i { lastOpenedIndex += 1 }
            if let focus = hoverFocus, focus >= i { hoverFocus = focus + 1 }
        }
        return i
    }

    /// Remove the head at `i`, keeping tracked indices valid and dropping any
    /// pin for that conversation.
    @discardableResult
    public mutating func remove(at i: Int) -> BubbleHead<Panel>? {
        guard heads.indices.contains(i) else { return nil }
        if lastOpenedIndex == i { lastOpenedIndex = 0 }
        else if lastOpenedIndex > i { lastOpenedIndex -= 1 }
        if anchorIndex == i { anchorIndex = 0 }
        else if anchorIndex > i { anchorIndex -= 1 }
        if let focus = hoverFocus {
            if focus == i { hoverFocus = nil }
            else if focus > i { hoverFocus = focus - 1 }
        }
        let removed = heads.remove(at: i)
        if let id = removed.conversationID { pinnedIDs.remove(id) }
        if anchorIndex >= heads.count { anchorIndex = max(0, heads.count - 1) }
        if lastOpenedIndex >= heads.count { lastOpenedIndex = max(0, heads.count - 1) }
        return removed
    }

    /// Move the head currently at `from` so it lands at index `destination`,
    /// remapping `anchorIndex`, `lastOpenedIndex` and `hoverFocus` to follow
    /// the same heads.
    public mutating func move(from: Int, to destination: Int) {
        guard from != destination,
              heads.indices.contains(from),
              heads.indices.contains(destination) else { return }
        let head = heads.remove(at: from)
        heads.insert(head, at: destination)

        func mapIndex(_ i: Int) -> Int {
            if i == from { return destination }
            if from < destination {
                return (i > from && i <= destination) ? i - 1 : i
            } else {
                return (i >= destination && i < from) ? i + 1 : i
            }
        }
        lastOpenedIndex = mapIndex(lastOpenedIndex)
        anchorIndex = mapIndex(anchorIndex)
        if let focus = hoverFocus { hoverFocus = mapIndex(focus) }
    }

    public mutating func removeAll(keepingPinned: Bool = true) {
        heads.removeAll()
        anchorIndex = 0
        lastOpenedIndex = 0
        hoverFocus = nil
        if !keepingPinned { pinnedIDs.removeAll() }
    }
}
