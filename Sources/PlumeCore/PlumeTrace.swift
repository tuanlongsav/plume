import CoreGraphics
import Foundation

// Diagnostic multi-display traces. No-op in release so notarized builds never
// write contact names / cursor positions to ~/plume-trace.log. The autoclosure
// keeps release builds from even formatting the line — some run every frame.
public enum PlumeTrace {
    public static let url = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("plume-trace.log")

    public static func log(_ line: @autoclosure () -> String) {
        #if DEBUG
        guard let d = (line() + "\n").data(using: .utf8) else { return }
        if let h = try? FileHandle(forWritingTo: url) {
            _ = try? h.seekToEnd(); try? h.write(contentsOf: d); try? h.close()
        } else {
            try? d.write(to: url)
        }
        #endif
    }

    public static func r(_ r: CGRect) -> String {
        String(format: "(%.0f,%.0f %.0fx%.0f)", r.minX, r.minY, r.width, r.height)
    }

    public static func p(_ p: CGPoint) -> String {
        String(format: "(%.0f,%.0f)", p.x, p.y)
    }
}
