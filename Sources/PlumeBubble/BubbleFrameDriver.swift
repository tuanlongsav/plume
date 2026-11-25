import AppKit
import QuartzCore

/// `now` in `CACurrentMediaTime()` time; `nominal` is the expected frame
/// interval.
typealias FrameHandler = (_ now: CFTimeInterval, _ nominal: CFTimeInterval) -> Void

/// What the bubble frame loop needs from a clock: frames until paused (zero
/// cost while paused, instant resume) and a way to stop for good.
protocol BubbleFrameDriver: AnyObject {
    var isPaused: Bool { get set }
    func invalidate()
}

/// Builds the appropriate frame driver for the current macOS version.
enum BubbleFrameDriverFactory {
    /// DEBUG only: `defaults write com.htl.plume plume.debugTimerFrames -bool
    /// YES` runs the macOS 13 frame driver on a newer Mac, so it can be tried
    /// without one.
    #if DEBUG
    private static let forceTimerFrames = UserDefaults.standard.bool(forKey: "plume.debugTimerFrames")
    #else
    private static let forceTimerFrames = false
    #endif

    /// macOS 14+ drives the chain from the display (`DisplayLinkFrameDriver`);
    /// macOS 13 has no display link on NSScreen and gets a 60 Hz timer.
    static func make(screen: NSScreen, onFrame: @escaping FrameHandler) -> BubbleFrameDriver {
        if #available(macOS 14.0, *), !forceTimerFrames {
            return DisplayLinkFrameDriver(screen: screen, onFrame: onFrame)
        }
        return TimerFrameDriver(onFrame: onFrame)
    }
}

/// macOS 14+: a display link from the chain's screen. The screen variant is
/// the right host: a view-hosted link stops firing when its view is hidden or
/// its panel is ordered out, freezing the chain mid-animation with nothing to
/// restart it. The link retains its target, this driver, which holds nothing
/// but the handler; `invalidate()` breaks that cycle.
@available(macOS 14.0, *)
private final class DisplayLinkFrameDriver: NSObject, BubbleFrameDriver {
    private var link: CADisplayLink?
    private let onFrame: FrameHandler

    init(screen: NSScreen, onFrame: @escaping FrameHandler) {
        self.onFrame = onFrame
        super.init()
        let l = screen.displayLink(target: self, selector: #selector(step(_:)))
        l.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        // .common, or the chain freezes for the whole drag: a mouse drag runs
        // the run loop in .eventTracking.
        l.add(to: .main, forMode: .common)
        link = l
    }

    var isPaused: Bool {
        get { link?.isPaused ?? true }
        set { link?.isPaused = newValue }
    }

    func invalidate() { link?.invalidate(); link = nil }

    // targetTimestamp deltas, never link.duration: duration is the display's
    // fastest frame and stays 1/120 on ProMotion even while the link runs at
    // 60, which would halve every animation. link.timestamp is 0 before the
    // link has ever fired, which is why the first frame uses `nominal`.
    @objc private func step(_ link: CADisplayLink) {
        onFrame(link.targetTimestamp, link.targetTimestamp - link.timestamp)
    }
}

/// macOS 13: NSScreen has no display link there. A 60 Hz timer in .common
/// mode (so it keeps firing through a drag) is less evenly paced than the
/// display, but the physics takes real time deltas, so motion is the same.
/// Chosen over CVDisplayLink, whose callbacks can still arrive after
/// CVDisplayLinkStop and race the link's release on every display change.
private final class TimerFrameDriver: BubbleFrameDriver {
    private static let interval: CFTimeInterval = 1.0 / 60.0
    private var timer: Timer?
    private let onFrame: FrameHandler

    init(onFrame: @escaping FrameHandler) {
        self.onFrame = onFrame
        start()
    }

    deinit { timer?.invalidate() }

    var isPaused: Bool {
        get { timer == nil }
        set { if newValue { invalidate() } else { start() } }
    }

    func invalidate() { timer?.invalidate(); timer = nil }

    private func start() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: Self.interval, repeats: true) { [weak self] _ in
            self?.onFrame(CACurrentMediaTime(), Self.interval)
        }
        t.tolerance = 0.002
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }
}
