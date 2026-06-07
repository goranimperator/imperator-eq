import SwiftUI

struct EQSlider: View {
    @Binding var value: Float
    let range: ClosedRange<Float>
    var centerNotch: Bool = false
    var snapToCenter: Bool = false

    private let trackHeight: CGFloat = 4
    private let thumbSize: CGFloat = 14
    private let snapThreshold: Float = 0.05

    private var normalized: CGFloat {
        CGFloat((value - range.lowerBound) / (range.upperBound - range.lowerBound))
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

                let fillRect = CGRect(
                    x: thumbSize / 2,
                    y: centerY - trackHeight / 2,
                    width: thumbCenterX - thumbSize / 2,
                    height: trackHeight
                )
                context.fill(
                    Path(fillRect),
                    with: .linearGradient(
                        Gradient(colors: AppColors.gradientColors.reversed()),
                        startPoint: CGPoint(x: fillRect.minX, y: 0),
                        endPoint: CGPoint(x: fillRect.maxX, y: 0)
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
