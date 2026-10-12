import AppKit
import TemperatureCore

/// Native, event-driven drawing. No animation / refresh timer or chart framework.
@MainActor
final class TemperatureChartView: NSView {
    private var points: [TemperaturePoint] = []
    private var timeWindow: TimeInterval = 60
    private var now: TimeInterval = 0
    private var threshold: Double = 70
    private(set) var minimum: Double?
    private(set) var maximum: Double?
    override var isFlipped: Bool { true }

    func update(points: [TemperaturePoint], window: TimeInterval, now: TimeInterval, threshold: Double) {
        guard self.points != points || self.timeWindow != window || self.now != now || self.threshold != threshold else { return }
        self.points = points; self.timeWindow = window; self.now = now; self.threshold = threshold
        let values = points.compactMap(\.temperature)
        minimum = values.min(); maximum = values.max()
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("最近 \(Int(window / 60)) 分钟温度曲线")
        setAccessibilityValue(minimum.map { String(format: "最低 %.1f°C，最高 %.1f°C，提醒阈值 %.0f°C", $0, maximum ?? $0, threshold) } ?? "等待采样")
        needsDisplay = true
    }

    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let plot = NSRect(x: 40, y: 10, width: max(1, bounds.width - 50), height: max(1, bounds.height - 38))
        let lower = max(0, floor((min(minimum ?? threshold, threshold) - 5) / 10) * 10)
        let upper = max(lower + 20, ceil((max(maximum ?? threshold, threshold) + 5) / 10) * 10)
        func y(_ value: Double) -> CGFloat { plot.maxY - (value - lower) / (upper - lower) * plot.height }
        func x(_ time: TimeInterval) -> CGFloat { plot.minX + (time - (now - timeWindow)) / timeWindow * plot.width }
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]
        for level in [lower, (lower + upper) / 2, upper] {
            let path = NSBezierPath()
            path.move(to: NSPoint(x: plot.minX, y: y(level)))
            path.line(to: NSPoint(x: plot.maxX, y: y(level)))
            path.lineWidth = 0.5
            NSColor.separatorColor.withAlphaComponent(0.5).setStroke()
            path.stroke()
            let text = NSString(string: String(format: "%.0f°", level))
            let size = text.size(withAttributes: attributes)
            text.draw(at: NSPoint(x: plot.minX - size.width - 6, y: y(level) - size.height / 2), withAttributes: attributes)
        }
        let reminder = NSBezierPath()
        reminder.move(to: NSPoint(x: plot.minX, y: y(threshold)))
        reminder.line(to: NSPoint(x: plot.maxX, y: y(threshold)))
        reminder.setLineDash([4, 3], count: 2, phase: 0)
        reminder.lineWidth = 1
        NSColor.systemOrange.withAlphaComponent(0.7).setStroke()
        reminder.stroke()

        let line = NSBezierPath()
        let area = NSBezierPath()
        var start: NSPoint?
        var end: NSPoint?
        func endSegment() {
            if let start, let end {
                area.line(to: NSPoint(x: end.x, y: plot.maxY))
                area.line(to: NSPoint(x: start.x, y: plot.maxY))
                area.close()
            }
            start = nil; end = nil
        }
        for point in points {
            guard let value = point.temperature else { endSegment(); continue }
            let position = NSPoint(x: x(point.time), y: y(value))
            if point.startsNewSegment || start == nil {
                endSegment()
                line.move(to: position); area.move(to: position); start = position
            } else { line.line(to: position); area.line(to: position) }
            end = position
        }
        endSegment()
        if !area.isEmpty {
            NSGradient(starting: NSColor.systemBlue.withAlphaComponent(0.03), ending: NSColor.systemBlue.withAlphaComponent(0.16))?.draw(in: area, angle: 90)
        }
        NSColor.systemBlue.setStroke()
        line.lineWidth = 1.8; line.lineCapStyle = .round; line.lineJoinStyle = .round
        line.stroke()
        if let point = points.last, let value = point.temperature {
            NSColor.systemBlue.setFill()
            NSBezierPath(ovalIn: NSRect(x: x(point.time) - 3, y: y(value) - 3, width: 6, height: 6)).fill()
        }
        NSString(string: "\(Int(timeWindow / 60)) 分钟前").draw(at: NSPoint(x: plot.minX, y: plot.maxY + 7), withAttributes: attributes)
        let current = NSString(string: "现在")
        current.draw(at: NSPoint(x: plot.maxX - current.size(withAttributes: attributes).width, y: plot.maxY + 7), withAttributes: attributes)
        if minimum == nil {
            let text = NSString(string: "等待温度采样…")
            let size = text.size(withAttributes: attributes)
            text.draw(at: NSPoint(x: plot.midX - size.width / 2, y: plot.midY - size.height / 2), withAttributes: attributes)
        }
    }
}
