import AppKit

// MARK: - Bubble content

/// Tuning for the bubble chain. Geometry first, then the springs.
enum Chain {
    // canvas == peak is load-bearing: the panel never resizes, so a magnified
    // circle can never be clipped, and magnification never moves a bubble —
    // which is what lets hover be measured against live positions without the
    // scale → layout → distance → scale feedback loop the real Dock must fight.
    /// Resting circle — the one number the user sets.
    static var base: CGFloat { Preferences.bubbleSize }
    /// Circle under the cursor. 2× so the hovered head clearly dominates its
    /// neighbours (Dock-strong); the neighbour weight below keeps them modest.
    static var peak: CGFloat { (base * 2.0).rounded() }
    /// Panel edge. Equal to `peak` for the life of a panel so magnification
    /// never clips — independent of how tightly the chain is packed.
    static var canvas: CGFloat { peak }
    /// Centre-to-centre at rest — nearly touching (≈4pt edge gap), independent
    /// of Dock magnification.
    static var step: CGFloat { (base + 4).rounded() }
    static let margin: CGFloat = 6         // gap to visibleFrame at rest

    /// Anchor spring — the released bubble flying to the edge.
    static let anchorOmega: CGFloat = 13
    static let anchorZeta: CGFloat = 0.9
    static let maxOvershoot: CGFloat = 10  // pt past the rest line, hard clamp

    /// Followers. τ is the lag behind the bubble in front; ω = 2ζ/τ. Ramping τ
    /// down the chain makes it unfurl instead of sliding rigidly.
    static let trailZeta: CGFloat = 0.8
    static func trailTau(_ k: Int) -> CGFloat { 0.050 + 0.008 * CGFloat(min(k, 5) - 1) }

    static let dtMin: CGFloat = 1.0 / 240
    static let dtMax: CGFloat = 1.0 / 30   // ω·dt ≤ 1.07 at the stiffest link

    /// Flick measurement. A mouse polls at 125Hz and a trackpad at ~90, so the
    /// span gate has to be reachable within a handful of samples.
    static let velWindow: CFTimeInterval = 0.060
    static let velMinSpan: CFTimeInterval = 0.015
    static let velSamples = 6
    static let velStaleGate: CFTimeInterval = 0.060
    static let flickFloor: CGFloat = 320   // below this the position picks the edge
    static let maxFlick: CGFloat = 2600
    static let projectTauX: CGFloat = 0.12
    static let projectTauY: CGFloat = 0.06
    static let dragSlop: CGFloat = 3

    /// Release velocity: a regression over a trailing time window. An EMA
    /// with a fixed coefficient over uneven dt would make flick strength
    /// depend on whether the user is on a 125Hz mouse or a 90Hz trackpad.
    static func flickVelocity(_ samples: [(p: NSPoint, t: CFTimeInterval)],
                              now: CFTimeInterval = CACurrentMediaTime()) -> NSPoint {
        guard let last = samples.last, now - last.t <= velStaleGate else { return .zero }
        let window = samples.filter { last.t - $0.t <= velWindow }
        guard let first = window.first, window.count >= 2 else { return .zero }
        let span = last.t - first.t
        guard span >= velMinSpan else { return .zero }
        return NSPoint(x: (last.p.x - first.p.x) / CGFloat(span),
                       y: (last.p.y - first.p.y) / CGFloat(span))
    }

    /// Constant visual edge gap while packing (rest and magnified).
    static var magGap: CGFloat { step - base }
    /// Centre-to-centre between two live diameters (Dock packing).
    static func linkSpacing(_ a: CGFloat, _ b: CGFloat) -> CGFloat {
        (a + b) / 2 + magGap
    }

    /// X centres of a docked row: packed left-to-right, then centered on `card`.
    /// If the row is wider than the card it pins to the right inset (same as
    /// before) and is then nudged onto `visible` so a head never leaves the screen.
    static func dockedRowXs(diameters: [CGFloat], card: CGRect,
                            visible: CGRect, pad: CGFloat = 8) -> [CGFloat] {
        guard !diameters.isEmpty else { return [] }
        var xs: [CGFloat] = []
        xs.reserveCapacity(diameters.count)
        for i in diameters.indices {
            if i == 0 {
                xs.append(diameters[i] / 2)
            } else {
                xs.append(xs[i - 1] + linkSpacing(diameters[i - 1], diameters[i]))
            }
        }
        let last = xs.count - 1
        let groupWidth = xs[last] + diameters[last] / 2
        let innerLeft = card.minX + pad
        let innerRight = card.maxX - pad
        let innerWidth = innerRight - innerLeft
        var origin = card.midX - groupWidth / 2
        if groupWidth <= innerWidth {
            origin = min(max(origin, innerLeft), innerRight - groupWidth)
        } else {
            origin = innerLeft
        }
        for i in xs.indices { xs[i] += origin }

        let overflow = xs[last] + diameters[last] / 2 + pad - card.maxX
        if overflow > 0 {
            for i in xs.indices { xs[i] -= overflow }
        }
        let minAllowed = visible.minX + peak / 2 + 2
        if let first = xs.first, first < minAllowed {
            let dx = minAllowed - first
            for i in xs.indices { xs[i] += dx }
        }
        return xs
    }
    /// Fraction of (peak−base) for the adjacent slot. Low enough that the
    /// neighbour never reads as "almost as big" as the hovered head.
    static let magNeighbour: CGFloat = 0.26
    static let magNextNeighbour: CGFloat = 0.05
    /// While the card is open, the owning head stays at least this large even
    /// when the pointer is over a neighbour — so you can see which chat is live.
    static let openBoost: CGFloat = 0.62
    /// Higher = snappier hover response (settles in ~3–4 frames at 120Hz).
    static let magRate: CGFloat = 36
    static let magEpsilon: CGFloat = 0.05
    static let pressScale: CGFloat = 0.93

    static let restDistance: CGFloat = 0.3
    static let restSpeed: CGFloat = 1.5

    /// Exact closed-form step of a damped spring toward `target` over `dt`.
    /// Identical motion at 60 and 120Hz; cannot blow up on a stalled frame.
    @inline(__always)
    static func spring(_ x: inout CGFloat, _ v: inout CGFloat,
                       to target: CGFloat, omega w: CGFloat,
                       zeta z: CGFloat, dt: CGFloat) {
        let d = x - target
        if z < 0.999 {                                  // underdamped
            let wd = w * (1 - z * z).squareRoot()
            let e = exp(-z * w * dt)
            let c = cos(wd * dt), s = sin(wd * dt)
            let a = d, b = (v + z * w * d) / wd
            x = target + e * (a * c + b * s)
            v = e * ((b * wd - z * w * a) * c - (a * wd + z * w * b) * s)
        } else if z < 1.001 {                           // critically damped
            let e = exp(-w * dt)
            let a = d, b = v + w * d
            x = target + e * (a + b * dt)
            v = e * (b - w * (a + b * dt))
        } else {                                        // overdamped
            let r = w * (z * z - 1).squareRoot()
            let r1 = -z * w + r, r2 = -z * w - r
            let c2 = (v - r1 * d) / (r2 - r1)
            let c1 = d - c2
            let e1 = exp(r1 * dt), e2 = exp(r2 * dt)
            x = target + c1 * e1 + c2 * e2
            v = c1 * r1 * e1 + c2 * r2 * e2
        }
    }

    @inline(__always)
    static func clamp(_ x: inout CGFloat, _ v: inout CGFloat, _ lo: CGFloat, _ hi: CGFloat) {
        guard lo <= hi else { x = min(max(x, hi), lo); v = 0; return }
        if x < lo { x = lo; if v < 0 { v = 0 } }
        else if x > hi { x = hi; if v > 0 { v = 0 } }
    }
}
