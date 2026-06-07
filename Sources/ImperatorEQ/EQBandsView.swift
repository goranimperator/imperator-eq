import SwiftUI

struct EQBandsView: View {
    @Binding var bands: [EQBand]
    let isEnabled: Bool

    var body: some View {
        GeometryReader { geometry in
            let bandWidth = geometry.size.width / CGFloat(bands.count)
            let maxHeight = geometry.size.height - 24

            HStack(spacing: 0) {
                ForEach(bands.indices, id: \.self) { index in
                    EQBandColumn(
                        band: $bands[index],
                        maxHeight: maxHeight,
                        width: bandWidth,
                        isEnabled: isEnabled
                    )
                }
            }
        }
    }
}

struct EQBandColumn: View {
    @Binding var band: EQBand
    let maxHeight: CGFloat
    let width: CGFloat
    let isEnabled: Bool

    @State private var isDragging = false

    private let maxGain: Float = 12.0
    private let brandRed = AppColors.brand

    private var normalizedGain: CGFloat {
        CGFloat((band.gain + maxGain) / (2 * maxGain))
    }

    var body: some View {
        VStack(spacing: 4) {
            ZStack(alignment: .bottom) {
                Rectangle()
                    .fill(Color.gray.opacity(0.15))
                    .frame(width: width * 0.4, height: maxHeight)

                Rectangle()
                    .fill(bandGradient)
                    .frame(
                        width: width * 0.4,
                        height: max(2, normalizedGain * maxHeight)
                    )
                    .opacity(isEnabled ? 1.0 : 0.3)

                ForEach(0..<11, id: \.self) { tick in
                    let tickY = CGFloat(tick) / 10.0 * maxHeight
                    Rectangle()
                        .fill(Color.white.opacity(tick == 0 || tick == 5 || tick == 10 ? 0.3 : 0.15))
                        .frame(width: tick == 0 || tick == 5 || tick == 10 ? width * 0.8 : width * 0.5 + 4, height: tick == 0 || tick == 5 || tick == 10 ? 1 : 0.5)
                        .offset(y: -(tickY - 0.5))
                }

                let fillHeight = normalizedGain * maxHeight
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.secondary)
                    .frame(width: width * 0.5, height: 14)
                    .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
                    .offset(y: -(fillHeight - 7))
                    .opacity(isEnabled ? 1.0 : 0.3)
            }
            .frame(height: maxHeight)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) {
                band.gain = 0.0
            }
            .gesture(
                DragGesture(minimumDistance: 2)
                    .onChanged { value in
                        isDragging = true
                        let normalizedY = 1.0 - (value.location.y / maxHeight)
                        let clamped = max(0.0, min(1.0, normalizedY))
                        band.gain = Float(clamped) * 2 * maxGain - maxGain
                    }
                    .onEnded { _ in
                        isDragging = false
                    }
            )

            Text(band.frequency)
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .frame(height: 16)
        }
        .frame(width: width)
    }

    private var bandGradient: LinearGradient {
        LinearGradient(colors: AppColors.gradientColors, startPoint: .top, endPoint: .bottom)
    }
}
