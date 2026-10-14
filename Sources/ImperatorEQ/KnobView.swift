import AppKit
import SwiftUI

/// A rotary knob for the CONTROLS section, turned the way Logic Pro's are:
/// press and drag up to raise it, down to lower it. Shift drags four times
/// finer, Option-click and double-click return it to 0.
///
/// The value moves in whole steps over `range`. A range that spans 0 (Bass, Mid,
/// Treble, Gain: -10...10) is bipolar: 0 sits at 12 o'clock and the red arc and
/// the lit ticks grow from there towards the value. A range that starts at 0
/// (Warmth: 0...10) grows from the bottom left, like the reference. The dot on
/// the face is the same grey as the slider thumbs (`.secondary`): brand red
/// measures 1.73:1 on this panel, so the red marks cannot be the only thing that
/// shows where the knob points.
struct KnobView: View {
    let name: String
    @Binding var value: Float
    let range: ClosedRange<Float>
    var isEnabled = true

    /// Where the current drag counts from: the value and the pointer's height
    /// when it began, or when Shift was last pressed or released, so changing the
    /// step size mid-drag never makes the value jump. Gesture state, so a drag cut
    /// off by the panel closing leaves nothing behind for the next one.
    struct DragOrigin {
        var value: Float
        var y: CGFloat
        var isFine: Bool
    }

    /// One drag update: the origin, moved to here if Shift changed since the
    /// last one, and the value the pointer's height `y` asks for, unrounded.
    static func dragStep(from origin: DragOrigin?, value: Float, y: CGFloat,
                         isFine: Bool) -> (origin: DragOrigin, value: Float) {
        var start = origin ?? DragOrigin(value: value, y: y, isFine: isFine)
        if start.isFine != isFine { start = DragOrigin(value: value, y: y, isFine: isFine) }
        let perStep = isFine ? pointsPerStep * 4 : pointsPerStep
        return (start, start.value + Float(-(y - start.y) / perStep))
    }

    @GestureState private var dragOrigin: DragOrigin?
    @State private var isHovered = false

    /// 270 degrees of travel, from 7:30 round to 4:30, in screen angles
    /// (clockwise from 3 o'clock).
    private static let startAngle = 135.0
    private static let sweep = 270.0
    private static let tickCount = 21
    private static let pointsPerStep: CGFloat = 10
    /// Six across the 308 pt inside the panel's padding.
    private static let dialSize: CGFloat = 48

    var body: some View {
        VStack(spacing: 4) {
            dial
                .frame(width: Self.dialSize, height: Self.dialSize)
                .contentShape(Circle())
                .gesture(drag)
                .simultaneousGesture(TapGesture(count: 2).onEnded { setValue(0) })
                .onHover { isHovered = $0 }

            // The value replaces the name while the knob is touched or pointed at.
            // The same text style as the equaliser's Reset.
            Text(isHovered || dragOrigin != nil ? formatted : name)
                .font(.caption)
                .foregroundStyle(isHovered || dragOrigin != nil ? .primary : .secondary)
                .monospacedDigit()
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .opacity(isEnabled ? 1 : 0.3)
        .accessibilityElement()
        .accessibilityLabel(name)
        .accessibilityValue(formatted)
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: setValue(value + 1)
            case .decrement: setValue(value - 1)
            @unknown default: break
            }
        }
    }

    private var formatted: String {
        let steps = Int(value.rounded())
        return range.lowerBound < 0 && steps > 0 ? "+\(steps)" : "\(steps)"
    }

    private func fraction(_ v: Float) -> Double {
        Double((v - range.lowerBound) / (range.upperBound - range.lowerBound))
    }

    private func angle(_ fraction: Double) -> Angle {
        .degrees(Self.startAngle + fraction * Self.sweep)
    }

    private func setValue(_ newValue: Float) {
        let clamped = min(max(newValue.rounded(), range.lowerBound), range.upperBound)
        if clamped != value { value = clamped }
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 0)
            .updating($dragOrigin) { gesture, origin, _ in
                if origin == nil, NSEvent.modifierFlags.contains(.option) { setValue(0) }
                let step = Self.dragStep(from: origin, value: value, y: gesture.translation.height,
                                         isFine: NSEvent.modifierFlags.contains(.shift))
                origin = step.origin
                setValue(step.value)
            }
    }

    private var dial: some View {
        Canvas { context, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let radius = min(size.width, size.height) / 2
            let zero = fraction(min(max(0, range.lowerBound), range.upperBound))
            let current = fraction(value)
            let low = min(zero, current)
            let high = max(zero, current)
            let lit = value != 0

            func point(_ angle: Angle, _ distance: CGFloat) -> CGPoint {
                CGPoint(x: center.x + distance * CGFloat(cos(angle.radians)),
                        y: center.y + distance * CGFloat(sin(angle.radians)))
            }

            // Ticks round the travel: red between 0 and the value, grey elsewhere.
            for i in 0..<Self.tickCount {
                let t = Double(i) / Double(Self.tickCount - 1)
                let major = i % 5 == 0
                var tick = Path()
                tick.move(to: point(angle(t), radius - (major ? 6 : 4)))
                tick.addLine(to: point(angle(t), radius - 1))
                let isLit = lit && t >= low - 0.0001 && t <= high + 0.0001
                context.stroke(tick, with: .color(isLit ? AppColors.brand : Color.white.opacity(major ? 0.3 : 0.15)),
                               lineWidth: major ? 1.5 : 1)
            }

            // The arc: a faint track over the whole travel, red over the set part.
            let arcRadius = radius - 8.5
            var track = Path()
            track.addArc(center: center, radius: arcRadius, startAngle: angle(0), endAngle: angle(1), clockwise: false)
            context.stroke(track, with: .color(Color.white.opacity(0.08)), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
            if lit {
                var arc = Path()
                arc.addArc(center: center, radius: arcRadius, startAngle: angle(low), endAngle: angle(high),
                           clockwise: false)
                context.stroke(arc, with: .color(AppColors.brand), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
            }

            // The knob face, and the dot that points at the value.
            let faceRadius = radius - 12
            let face = Path(ellipseIn: CGRect(x: center.x - faceRadius, y: center.y - faceRadius,
                                              width: faceRadius * 2, height: faceRadius * 2))
            context.fill(face, with: .linearGradient(Gradient(colors: [Color(white: 0.30), Color(white: 0.16)]),
                                                     startPoint: CGPoint(x: center.x, y: center.y - faceRadius),
                                                     endPoint: CGPoint(x: center.x, y: center.y + faceRadius)))
            context.stroke(face, with: .color(Color.white.opacity(0.12)), lineWidth: 1)
            let dot = point(angle(current), faceRadius * 0.62)
            context.fill(Path(ellipseIn: CGRect(x: dot.x - 2, y: dot.y - 2, width: 4, height: 4)),
                         with: .color(.secondary))
        }
    }
}
