import AppKit

/// The Plume "feather" mark, drawn as vector layers (no bitmap) from the SVG
/// paths in the design handoff (viewBox 0 0 64 72). Two variants:
/// - `.fullColor`: leaf filled with the blue→indigo gradient + indigo spine/barbs
///   (splash / branding).
/// - `.mono`: leaf outline + spine in a single colour (offline / small sizes).
final class FeatherView: NSView {

    enum Variant { case fullColor, mono }

    private let variant: Variant
    private var monoColor: NSColor

    // fullColor layers
    private let gradient = CAGradientLayer()
    private let leafMask = CAShapeLayer()
    private let detail = CAShapeLayer()   // spine + barbs, stroked
    // mono layers
    private let outline = CAShapeLayer()
    private let spine = CAShapeLayer()

    /// Everything lives in this container, sized to the 64×72 viewBox and then
    /// scaled to fit `bounds` — so paths & line widths are authored once.
    private let container = CALayer()

    init(variant: Variant, monoColor: NSColor = Theme.textTertiary) {
        self.variant = variant
        self.monoColor = monoColor
        super.init(frame: .zero)
        wantsLayer = true
        layer?.addSublayer(container)
        container.bounds = CGRect(x: 0, y: 0, width: 64, height: 72)
        container.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        buildLayers()
        refreshColors()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been used") }

    override var intrinsicContentSize: NSSize { NSSize(width: 64, height: 72) }

    // MARK: Layer construction

    private func buildLayers() {
        let leaf = Self.leafPath()
        let strokes = Self.spineAndBarbsPath(includeBarbs: variant == .fullColor)

        switch variant {
        case .fullColor:
            gradient.frame = container.bounds
            gradient.startPoint = CGPoint(x: 0, y: 1)   // 135° blue→indigo
            gradient.endPoint = CGPoint(x: 1, y: 0)
            gradient.colors = Theme.gradientColors
            leafMask.path = leaf
            leafMask.fillColor = NSColor.black.cgColor   // mask alpha only
            gradient.mask = leafMask
            container.addSublayer(gradient)

            detail.path = strokes
            detail.fillColor = NSColor.clear.cgColor
            detail.lineWidth = 1.7
            detail.lineCap = .round
            container.addSublayer(detail)

        case .mono:
            outline.path = leaf
            outline.fillColor = NSColor.clear.cgColor
            outline.lineWidth = 2.4
            outline.lineJoin = .round
            container.addSublayer(outline)

            spine.path = strokes
            spine.fillColor = NSColor.clear.cgColor
            spine.lineWidth = 2.0
            spine.lineCap = .round
            container.addSublayer(spine)
        }
    }

    /// Re-resolve appearance-dependent colours (mono variant). Call on init and
    /// when the effective appearance changes.
    func refreshColors() {
        withEffectiveAppearance {
            switch variant {
            case .fullColor:
                gradient.colors = Theme.gradientColors
                detail.strokeColor = Theme.indigo700.withAlphaComponent(0.55).cgColor
            case .mono:
                outline.strokeColor = monoColor.cgColor
                spine.strokeColor = monoColor.cgColor
            }
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshColors()
    }

    override func layout() {
        super.layout()
        // Scale the 64×72 container to fit, centred; disable implicit animation.
        let scale = min(bounds.width / 64, bounds.height / 72)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        container.position = CGPoint(x: bounds.midX, y: bounds.midY)
        container.transform = CATransform3DMakeScale(scale, scale, 1)
        gradient.frame = container.bounds
        CATransaction.commit()
    }

    // MARK: Breathing animation (splash)

    /// scale 1→1.055, opacity .86→1, 3.6s ease-in-out, infinite. No-op under
    /// Reduce Motion.
    func startBreathing() {
        guard !Theme.reduceMotion else { return }
        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 1.0
        scale.toValue = 1.055
        let opacity = CABasicAnimation(keyPath: "opacity")
        opacity.fromValue = 0.86
        opacity.toValue = 1.0
        let group = CAAnimationGroup()
        group.animations = [scale, opacity]
        group.duration = 3.6
        group.autoreverses = true
        group.repeatCount = .infinity
        group.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer?.add(group, forKey: "breathing")
    }

    func stopBreathing() { layer?.removeAnimation(forKey: "breathing") }

    // MARK: Paths (viewBox coords, y flipped to CALayer's y-up space)

    private static func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
        CGPoint(x: x, y: 72 - y)   // flip SVG y-down → layer y-up
    }

    private static func leafPath() -> CGPath {
        let path = CGMutablePath()
        path.move(to: p(32, 3))
        path.addCurve(to: p(34, 68), control1: p(49, 20), control2: p(49, 50))
        path.addCurve(to: p(30, 68), control1: p(33, 69.4), control2: p(31, 69.4))
        path.addCurve(to: p(32, 3),  control1: p(15, 50), control2: p(15, 20))
        path.closeSubpath()
        return path
    }

    private static func spineAndBarbsPath(includeBarbs: Bool) -> CGPath {
        let path = CGMutablePath()
        // spine
        path.move(to: p(32, 11)); path.addLine(to: p(32, 63))
        guard includeBarbs else { return path }
        // barbs (left + mirrored right)
        let barbs: [(CGFloat, CGFloat, CGFloat, CGFloat)] = [
            (32, 22, 23, 27), (32, 22, 41, 27),
            (32, 30, 21, 37), (32, 30, 43, 37),
            (32, 38, 22, 45), (32, 38, 42, 45),
            (32, 46, 25, 52), (32, 46, 39, 52),
        ]
        for (x0, y0, x1, y1) in barbs {
            path.move(to: p(x0, y0)); path.addLine(to: p(x1, y1))
        }
        return path
    }
}
