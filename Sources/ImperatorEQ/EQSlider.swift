import SwiftUI

struct EQSlider: View {
    @Binding var value: Float
    let range: ClosedRange<Float>
    var snapToCenter: Bool = false

    private let trackHeight: CGFloat = 4
    private let thumbSize: CGFloat = 14
    private let snapThreshold: Float = 0.05

    private var normalized: CGFloat {
        CGFloat((value - range.lowerBound) / (range.upperBound - range.lowerBound))
    }

    /// Where 0 sits on the track, or the nearer end when the range leaves it out.
    private var zeroNormalized: CGFloat {
        let zero = min(max(0, range.lowerBound), range.upperBound)
        return CGFloat((zero - range.lowerBound) / (range.upperBound - range.lowerBound))
    }

    private var centerValue: Float {
        (range.lowerBound + range.upperBound) / 2
    }

    var body: some View {
        GeometryReader { geometry in
            let totalWidth = geometry.size.width
            let trackWidth = totalWidth - thumbSize
            let thumbCenterX = thumbSize / 2 + normalized * trackWidth
            let centerY = geometry.size.height / 2

            Canvas { context, size in
                let trackRect = CGRect(
                    x: thumbSize / 2,
                    y: centerY - trackHeight / 2,
                    width: trackWidth,
                    height: trackHeight
                )
                context.fill(
                    Path(trackRect),
                    with: .color(Color.gray.opacity(0.2))
                )

                // The fill grows from 0 towards the thumb: from the middle on a
                // range that spans 0 (balance), so centred shows no fill.
                let zeroX = thumbSize / 2 + zeroNormalized * trackWidth
                let fillRect = CGRect(
                    x: min(zeroX, thumbCenterX),
                    y: centerY - trackHeight / 2,
                    width: abs(thumbCenterX - zeroX),
                    height: trackHeight
                )
                context.fill(
                    Path(fillRect),
                    with: .linearGradient(
                        Gradient(colors: AppColors.gradientColors.reversed()),
                        startPoint: CGPoint(x: zeroX, y: 0),
                        endPoint: CGPoint(x: thumbCenterX, y: 0)
                    )
                )

                for tick in 0...10 {
                    let tickX = thumbSize / 2 + CGFloat(tick) / 10.0 * trackWidth
                    let isMajor = tick == 0 || tick == 5 || tick == 10
                    let tickH: CGFloat = isMajor ? 10 : 6
                    let tickW: CGFloat = isMajor ? 1 : 0.5
                    let tickOpacity: Double = isMajor ? 0.3 : 0.15
                    let tickRect = CGRect(x: tickX - tickW / 2, y: centerY - tickH / 2, width: tickW, height: tickH)
                    context.fill(
                        Path(tickRect),
                        with: .color(Color.white.opacity(tickOpacity))
                    )
                }
            }

            Circle()
                .fill(Color.secondary)
                .frame(width: thumbSize, height: thumbSize)
                .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
                .position(x: thumbCenterX, y: centerY)

            Color.clear
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { drag in
                            let rel = drag.location.x - thumbSize / 2
                            let clamped = max(0, min(trackWidth, rel))
                            let norm = Float(clamped / trackWidth)
                            var newValue = range.lowerBound + norm * (range.upperBound - range.lowerBound)
                            if snapToCenter && abs(newValue - centerValue) < snapThreshold * (range.upperBound - range.lowerBound) {
                                newValue = centerValue
                            }
                            value = newValue
                        }
                )
        }
        .frame(height: 20)
    }
}
