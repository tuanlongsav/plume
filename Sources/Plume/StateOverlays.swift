import AppKit

// MARK: - Shared helpers

private func makeLabel(_ text: String, size: CGFloat, weight: NSFont.Weight,
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

/// Base for the opaque state screens: fills its parent with the state bg and
/// re-resolves it on appearance change.
class OverlayView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        refreshBackground()
    }
    required init?(coder: NSCoder) { fatalError() }

    func refreshBackground() {
        withEffectiveAppearance { layer?.backgroundColor = Theme.stateBackground.cgColor }
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshBackground()
    }
}

// MARK: - Spinner (rotating arc)

final class SpinnerView: NSView {
    private let arc = CAShapeLayer()
    private let diameter: CGFloat

    init(diameter: CGFloat = 14, lineWidth: CGFloat = 2, color: NSColor = Theme.accent) {
        self.diameter = diameter
        super.init(frame: NSRect(x: 0, y: 0, width: diameter, height: diameter))
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        let inset = lineWidth / 2
        let rect = CGRect(x: inset, y: inset, width: diameter - lineWidth, height: diameter - lineWidth)
        arc.path = CGPath(ellipseIn: rect, transform: nil)
        arc.fillColor = NSColor.clear.cgColor
        arc.strokeColor = color.cgColor
        arc.lineWidth = lineWidth
        arc.lineCap = .round
        arc.strokeStart = 0
        arc.strokeEnd = 0.72        // transparent "gap" at the top
        arc.frame = bounds
        layer?.addSublayer(arc)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: diameter, height: diameter) }

    func start() {
        guard !Theme.reduceMotion else { return }
        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.fromValue = 0
        spin.toValue = -Double.pi * 2
        spin.duration = 0.7
        spin.repeatCount = .infinity
        arc.add(spin, forKey: "spin")
    }
    func stop() { arc.removeAnimation(forKey: "spin") }
}

// MARK: - Shimmer bar (splash)

final class ShimmerBar: NSView {
    private let gradient = CAGradientLayer()

    init() {
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
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: 132, height: 3) }

    private func refreshTrack() {
        withEffectiveAppearance {
            layer?.backgroundColor = NSColor.tertiaryLabelColor.withAlphaComponent(0.18).cgColor
        }
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshTrack()
    }
    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        gradient.frame = bounds
        CATransaction.commit()
    }
    func start() {
        guard !Theme.reduceMotion else { return }
        let anim = CABasicAnimation(keyPath: "locations")
        anim.fromValue = [-0.3, 0.0, 0.3]
        anim.toValue = [0.7, 1.0, 1.3]
        anim.duration = 1.6
        anim.repeatCount = .infinity
        gradient.add(anim, forKey: "shimmer")
    }
    func stop() { gradient.removeAnimation(forKey: "shimmer") }
}

// MARK: - Indeterminate progress bar (loading)

final class ProgressBar: NSView {
    private let segment = CALayer()
    private var running = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        segment.backgroundColor = Theme.accent.cgColor
        layer?.addSublayer(segment)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 2.5) }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        segment.frame = CGRect(x: 0, y: 0, width: bounds.width * 0.3, height: bounds.height)
        CATransaction.commit()
        // (Re)bind the animation to the current width once we actually have one.
        restart()
    }
    func start() { running = true; restart() }
    func stop() { running = false; segment.removeAnimation(forKey: "progress") }

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
    }
}

// MARK: - Primary gradient button ("Thử lại")

final class GradientButton: NSButton {
    private let gradient = CAGradientLayer()
    private let hover = CALayer()
    var onClick: (() -> Void)?

    init(title: String) {
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        isBordered = false
        bezelStyle = .regularSquare
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
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize {
        NSSize(width: super.intrinsicContentSize.width + 52, height: 38)   // padding 10×26
    }
    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        gradient.frame = bounds
        hover.frame = bounds
        CATransaction.commit()
    }
    private var tracker: NSTrackingArea?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracker { removeTrackingArea(tracker) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp],
                               owner: self, userInfo: nil)
        addTrackingArea(t); tracker = t
    }
    override func mouseEntered(with event: NSEvent) { hover.isHidden = false }
    override func mouseExited(with event: NSEvent) { hover.isHidden = true }

    @objc private func clicked() { onClick?() }
}

// MARK: - Splash

final class SplashView: OverlayView {
    private let feather = FeatherView(variant: .fullColor)
    private let shimmer = ShimmerBar()

    override init(frame: NSRect) {
        super.init(frame: frame)
        let wordmark = makeLabel("Plume", size: 26, weight: .heavy,
                                 color: Theme.textPrimary, tracking: -0.52)
        let subtext = makeLabel(L.t("đang mở Messenger", "opening Messenger"),
                                size: 12.5, weight: .regular, color: Theme.textTertiary)
        feather.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [feather, wordmark, shimmer, subtext])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 16
        stack.setCustomSpacing(20, after: feather)
        stack.setCustomSpacing(18, after: wordmark)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            feather.widthAnchor.constraint(equalToConstant: 84),
            feather.heightAnchor.constraint(equalToConstant: 94),
            shimmer.widthAnchor.constraint(equalToConstant: 132),
            shimmer.heightAnchor.constraint(equalToConstant: 3),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func startAnimating() { feather.startBreathing(); shimmer.start() }
    func stopAnimating() { feather.stopBreathing(); shimmer.stop() }
}

// MARK: - Loading / reconnecting (non-blocking overlay)

final class LoadingView: NSView {
    private let dim = NSView()
    private let progress = ProgressBar()
    private let spinner = SpinnerView(diameter: 14)
    private let pill = NSVisualEffectView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false

        dim.wantsLayer = true
        dim.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.14).cgColor
        dim.translatesAutoresizingMaskIntoConstraints = false
        addSubview(dim)

        addSubview(progress)

        pill.material = .hudWindow
        pill.blendingMode = .withinWindow
        pill.state = .active
        pill.wantsLayer = true
        pill.layer?.cornerRadius = 18
        pill.layer?.masksToBounds = true
        pill.layer?.borderWidth = 1
        pill.layer?.borderColor = NSColor.separatorColor.cgColor
        pill.translatesAutoresizingMaskIntoConstraints = false

        let label = makeLabel(L.t("Đang kết nối lại…", "Reconnecting…"),
                              size: 12.5, weight: .semibold, color: Theme.textSecondary)
        label.alignment = .left
        let row = NSStackView(views: [spinner, label])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        pill.addSubview(row)
        addSubview(pill)

        NSLayoutConstraint.activate([
            dim.topAnchor.constraint(equalTo: topAnchor),
            dim.leadingAnchor.constraint(equalTo: leadingAnchor),
            dim.trailingAnchor.constraint(equalTo: trailingAnchor),
            dim.bottomAnchor.constraint(equalTo: bottomAnchor),

            progress.topAnchor.constraint(equalTo: topAnchor),
            progress.leadingAnchor.constraint(equalTo: leadingAnchor),
            progress.trailingAnchor.constraint(equalTo: trailingAnchor),
            progress.heightAnchor.constraint(equalToConstant: 2.5),

            pill.topAnchor.constraint(equalTo: topAnchor, constant: 16),
            pill.centerXAnchor.constraint(equalTo: centerXAnchor),

            row.leadingAnchor.constraint(equalTo: pill.leadingAnchor, constant: 12),
            row.trailingAnchor.constraint(equalTo: pill.trailingAnchor, constant: -15),
            row.topAnchor.constraint(equalTo: pill.topAnchor, constant: 7),
            row.bottomAnchor.constraint(equalTo: pill.bottomAnchor, constant: -7),
            spinner.widthAnchor.constraint(equalToConstant: 14),
            spinner.heightAnchor.constraint(equalToConstant: 14),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    // Non-interactive: let clicks fall through to the web view beneath.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func startAnimating() {
        layoutSubtreeIfNeeded()   // give the progress bar a width before it binds
        progress.start(); spinner.start()
    }
    func stopAnimating() { progress.stop(); spinner.stop() }
}

// MARK: - Offline / error

final class OfflineView: OverlayView {
    private let feather = FeatherView(variant: .mono)
    var onRetry: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)

        feather.translatesAutoresizingMaskIntoConstraints = false
        let title = makeLabel(L.t("Mất kết nối", "You're offline"),
                             size: 21, weight: .heavy, color: Theme.textPrimary)
        let subtitle = makeLabel(
            L.t("Không thể tải Messenger. Hãy kiểm tra kết nối mạng của bạn.",
                "Couldn't reach Messenger. Check your internet connection."),
            size: 14, weight: .regular, color: Theme.textSecondary)

        let button = GradientButton(title: L.t("Thử lại", "Try Again"))
        button.onClick = { [weak self] in self?.onRetry?() }

        let caption = makeLabel(L.t("Tự thử lại sau vài giây…", "Retrying automatically…"),
                               size: 12, weight: .regular, color: Theme.textTertiary)
        let retryIcon = NSImageView()
        retryIcon.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: nil)
        retryIcon.contentTintColor = Theme.textTertiary
        retryIcon.translatesAutoresizingMaskIntoConstraints = false
        let captionRow = NSStackView(views: [retryIcon, caption])
        captionRow.orientation = .horizontal
        captionRow.alignment = .centerY
        captionRow.spacing = 6

        let stack = NSStackView(views: [feather, title, subtitle, button, captionRow])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 15
        stack.setCustomSpacing(20, after: feather)
        stack.setCustomSpacing(22, after: subtitle)
        stack.setCustomSpacing(22, after: button)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 40),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -40),
            feather.widthAnchor.constraint(equalToConstant: 58),
            feather.heightAnchor.constraint(equalToConstant: 65),
            subtitle.widthAnchor.constraint(lessThanOrEqualToConstant: 340),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
}
