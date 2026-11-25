import AppKit
import QuartzCore

// MARK: - Shared label helper

enum OverlayLabel {
    static func make(_ text: String, size: CGFloat, weight: NSFont.Weight,
                     color: NSColor, tracking: CGFloat = 0) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: size, weight: weight)
        label.textColor = color
        label.alignment = .center
        label.maximumNumberOfLines = 0
        if tracking != 0 {
            label.attributedStringValue = NSAttributedString(
                string: text,
                attributes: [
                    .font: NSFont.systemFont(ofSize: size, weight: weight),
                    .foregroundColor: color,
                    .kern: tracking,
                ])
        }
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }
}

/// Base for the opaque state screens: fills its parent with the state bg and
/// re-resolves it on appearance change.
open class OverlayView: NSView {
    public override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        refreshBackground()
    }

    public required init?(coder: NSCoder) { fatalError() }

    public func refreshBackground() {
        withEffectiveAppearance { layer?.backgroundColor = Theme.stateBackground.cgColor }
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshBackground()
    }
}

// MARK: - Spinner (rotating arc)

public final class SpinnerView: NSView {
    private let arc = CAShapeLayer()
    private let diameter: CGFloat

    public init(diameter: CGFloat = 14) {
        self.diameter = diameter
        let lineWidth: CGFloat = 2
        super.init(frame: NSRect(x: 0, y: 0, width: diameter, height: diameter))
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        let inset = lineWidth / 2
        let rect = CGRect(x: inset, y: inset, width: diameter - lineWidth, height: diameter - lineWidth)
        arc.path = CGPath(ellipseIn: rect, transform: nil)
        arc.fillColor = NSColor.clear.cgColor
        arc.strokeColor = Theme.accent.cgColor
        arc.lineWidth = lineWidth
        arc.lineCap = .round
        arc.strokeStart = 0
        arc.strokeEnd = 0.72        // transparent "gap" at the top
        arc.frame = bounds
        layer?.addSublayer(arc)
    }

    public required init?(coder: NSCoder) { fatalError() }

    public override var intrinsicContentSize: NSSize { NSSize(width: diameter, height: diameter) }

    public func start() {
        guard !Theme.reduceMotion else { return }
        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.fromValue = 0
        spin.toValue = -Double.pi * 2
        spin.duration = 0.7
        spin.repeatCount = .infinity
        arc.add(spin, forKey: "spin")
    }

    public func stop() { arc.removeAnimation(forKey: "spin") }
}

// MARK: - Shimmer bar (splash)

public final class ShimmerBar: NSView {
    private let gradient = CAGradientLayer()

    public init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 132, height: 3))
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        layer?.cornerRadius = 1.5
        layer?.masksToBounds = true
        gradient.startPoint = CGPoint(x: 0, y: 0.5)
        gradient.endPoint = CGPoint(x: 1, y: 0.5)
        gradient.colors = [
            NSColor.clear.cgColor,
            Theme.accent.withAlphaComponent(0.9).cgColor,
            NSColor.clear.cgColor,
        ]
        gradient.locations = [-0.3, 0.0, 0.3]
        layer?.addSublayer(gradient)
        refreshTrack()
    }

    public required init?(coder: NSCoder) { fatalError() }

    public override var intrinsicContentSize: NSSize { NSSize(width: 132, height: 3) }

    private func refreshTrack() {
        withEffectiveAppearance {
            layer?.backgroundColor = NSColor.tertiaryLabelColor.withAlphaComponent(0.18).cgColor
        }
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshTrack()
    }

    public override func layout() {
        super.layout()
        CATransaction.withoutAnimation {
            gradient.frame = bounds
        }
    }

    public func start() {
        guard !Theme.reduceMotion else { return }
        let anim = CABasicAnimation(keyPath: "locations")
        anim.fromValue = [-0.3, 0.0, 0.3]
        anim.toValue = [0.7, 1.0, 1.3]
        anim.duration = 1.6
        anim.repeatCount = .infinity
        gradient.add(anim, forKey: "shimmer")
    }

    public func stop() { gradient.removeAnimation(forKey: "shimmer") }
}

// MARK: - Indeterminate progress bar (loading)

public final class ProgressBar: NSView {
    private let segment = CALayer()
    private var running = false
    private var animatedWidth: CGFloat = -1

    public override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        segment.backgroundColor = Theme.accent.cgColor
        layer?.addSublayer(segment)
    }

    public required init?(coder: NSCoder) { fatalError() }

    public override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 2.5) }

    public override func layout() {
        super.layout()
        CATransaction.withoutAnimation {
            segment.frame = CGRect(x: 0, y: 0, width: bounds.width * 0.3, height: bounds.height)
        }
        // (Re)bind the animation to the current width once we actually have
        // one. Only when it changed: layout passes are frequent, and each
        // restart would jump the bar back to its start.
        guard bounds.width != animatedWidth else { return }
        restart()
    }

    public func start() { running = true; restart() }
    public func stop() { running = false; animatedWidth = -1; segment.removeAnimation(forKey: "progress") }

    /// Animation values depend on the laid-out width, so this is a no-op until
    /// `bounds.width > 0`; `layout()` calls it again once that holds.
    private func restart() {
        guard running, !Theme.reduceMotion, bounds.width > 0 else { return }
        segment.removeAnimation(forKey: "progress")
        let w = bounds.width
        let anim = CABasicAnimation(keyPath: "position.x")
        anim.fromValue = -w * 0.3
        anim.toValue = w * 1.15
        anim.duration = 1.4
        anim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        anim.repeatCount = .infinity
        segment.add(anim, forKey: "progress")
        animatedWidth = w
    }
}

// MARK: - Primary gradient button ("Thử lại")

public final class GradientButton: NSButton {
    private let gradient = CAGradientLayer()
    private let hover = CALayer()
    private var tracker: NSTrackingArea?
    public var onClick: (() -> Void)?

    public init(title: String) {
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        isBordered = false
        bezelStyle = .flexiblePush
        attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 14, weight: .bold),
            .foregroundColor: NSColor.white,
        ])
        gradient.colors = Theme.gradientColors
        gradient.startPoint = CGPoint(x: 0, y: 1)
        gradient.endPoint = CGPoint(x: 1, y: 0)
        gradient.cornerRadius = 10
        layer?.addSublayer(gradient)
        hover.backgroundColor = NSColor.white.withAlphaComponent(0.10).cgColor
        hover.cornerRadius = 10
        hover.isHidden = true
        layer?.addSublayer(hover)
        layer?.cornerRadius = 10
        layer?.shadowColor = Theme.indigo700.cgColor
        layer?.shadowOpacity = 0.45
        layer?.shadowRadius = 9
        layer?.shadowOffset = CGSize(width: 0, height: -3)
        target = self
        action = #selector(clicked)
    }

    public required init?(coder: NSCoder) { fatalError() }

    public override var intrinsicContentSize: NSSize {
        NSSize(width: super.intrinsicContentSize.width + 52, height: 38)   // padding 10×26
    }

    public override func layout() {
        super.layout()
        CATransaction.withoutAnimation {
            gradient.frame = bounds
            hover.frame = bounds
        }
    }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracker { removeTrackingArea(tracker) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp],
                               owner: self, userInfo: nil)
        addTrackingArea(t); tracker = t
    }

    public override func mouseEntered(with event: NSEvent) { hover.isHidden = false }
    public override func mouseExited(with event: NSEvent) { hover.isHidden = true }

    @objc private func clicked() { onClick?() }
}
