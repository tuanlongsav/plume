import AppKit
import PlumeCore

// MARK: - Splash

public final class SplashView: OverlayView {
    private let feather = FeatherView(variant: .fullColor)
    private let shimmer = ShimmerBar()

    public override init(frame: NSRect) {
        super.init(frame: frame)
        let wordmark = OverlayLabel.make("Plume", size: 26, weight: .heavy,
                                         color: Theme.textPrimary, tracking: -0.52)
        let subtext = OverlayLabel.make(L.t("đang mở Messenger", "opening Messenger"),
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

    public required init?(coder: NSCoder) { fatalError() }

    public func startAnimating() { feather.startBreathing(); shimmer.start() }
    public func stopAnimating() { feather.stopBreathing(); shimmer.stop() }
}

// MARK: - Loading / reconnecting (non-blocking overlay)

public final class LoadingView: NSView {
    private let dim = NSView()
    private let progress = ProgressBar()
    private let spinner = SpinnerView(diameter: 14)
    private let pill = NSVisualEffectView()

    public override init(frame: NSRect) {
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
        pill.translatesAutoresizingMaskIntoConstraints = false

        let label = OverlayLabel.make(L.t("Đang tải…", "Loading…"),
                                      size: 12.5, weight: .semibold, color: Theme.textSecondary)
        label.alignment = .left
        let row = NSStackView(views: [spinner, label])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        pill.addSubview(row)
        addSubview(pill)
        refreshBorder()

        NSLayoutConstraint.activate(
            dim.pinEdges(to: self) + [
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
            ]
        )
    }

    public required init?(coder: NSCoder) { fatalError() }

    // Non-interactive: let clicks fall through to the web view beneath.
    public override func hitTest(_ point: NSPoint) -> NSView? { nil }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshBorder()
    }

    // separatorColor is dynamic; a captured cgColor wouldn't follow the theme.
    private func refreshBorder() {
        withEffectiveAppearance { pill.layer?.borderColor = NSColor.separatorColor.cgColor }
    }

    /// `dimmed` false shows just the progress bar + pill without darkening the
    /// page — used for a background attachment download, where the web view
    /// stays fully usable underneath.
    public func startAnimating(dimmed: Bool = true) {
        dim.isHidden = !dimmed
        layoutSubtreeIfNeeded()   // give the progress bar a width before it binds
        progress.start(); spinner.start()
    }

    public func stopAnimating() { progress.stop(); spinner.stop() }
}

// MARK: - Offline / error

public final class OfflineView: OverlayView {
    private let feather = FeatherView(variant: .mono)
    public var onRetry: (() -> Void)?

    public override init(frame: NSRect) {
        super.init(frame: frame)

        feather.translatesAutoresizingMaskIntoConstraints = false
        let title = OverlayLabel.make(L.t("Mất kết nối", "You're offline"),
                                      size: 21, weight: .heavy, color: Theme.textPrimary)
        let subtitle = OverlayLabel.make(
            L.t("Không thể tải Messenger. Hãy kiểm tra kết nối mạng của bạn.",
                "Couldn't reach Messenger. Check your internet connection."),
            size: 14, weight: .regular, color: Theme.textSecondary)

        let button = GradientButton(title: L.t("Thử lại", "Try Again"))
        button.onClick = { [weak self] in self?.onRetry?() }

        let caption = OverlayLabel.make(L.t("Tự thử lại sau vài giây…", "Retrying automatically…"),
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
        // The button's glow reaches past its bounds; macOS 13 clips views by
        // default (14 does not), so both levels opt out explicitly.
        stack.clipsToBounds = false
        button.clipsToBounds = false
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

    public required init?(coder: NSCoder) { fatalError() }
}
