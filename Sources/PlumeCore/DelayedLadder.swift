import Foundation

/// A cancellable ladder of delayed work items on a dispatch queue.
///
/// Each `schedule` call cancels any previous run and increments `generation`,
/// so stale callbacks (including asynchronous completions started by an earlier
/// step) can recognise they have been superseded and early cancellation stops
/// the remaining rungs cleanly.
public final class DelayedLadder {
    private var workItems: [DispatchWorkItem] = []
    public private(set) var generation = 0
    private let queue: DispatchQueue

    public init(queue: DispatchQueue = .main) {
        self.queue = queue
    }

    deinit {
        cancel()
    }

    public func cancel() {
        generation &+= 1
        workItems.forEach { $0.cancel() }
        workItems.removeAll()
    }

    /// Replace any active ladder with a new sequence at `delays`.
    public func schedule(delays: [TimeInterval],
                         action: @escaping (_ generation: Int) -> Void) {
        cancel()
        let gen = generation
        for delay in delays {
            let item = DispatchWorkItem { [weak self] in
                guard let self, self.generation == gen else { return }
                action(gen)
            }
            workItems.append(item)
            queue.asyncAfter(deadline: .now() + delay, execute: item)
        }
    }
}
