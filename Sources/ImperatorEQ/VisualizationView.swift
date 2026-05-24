import SwiftUI

struct VisualizationView: View {
    @StateObject private var engine = AudioEngine()

    var body: some View {
        VStack(spacing: 4) {
            HStack {
                Text("VISUALIZATION")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                HoverButton(action: {
                    if engine.isRunning {
                        engine.stop()
                    } else {
                        engine.start()
                    }
                }) {
                    Image(systemName: engine.isRunning ? "stop.fill" : "play.fill")
                        .font(.system(size: 10))
                }
            }

            if engine.isRunning {
                audioBarView
            } else {
                placeholderView
            }
        }
    }

    private var audioBarView: some View {
        GeometryReader { geometry in
            let barCount = engine.levels.count
            let barWidth = geometry.size.width / CGFloat(barCount) - 1

            HStack(spacing: 1) {
                ForEach(0..<barCount, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 1)
                        .fill(barGradient)
                        .frame(
                            width: barWidth,
                            height: max(2, CGFloat(engine.levels[i]) * geometry.size.height)
                        )
                        .frame(maxHeight: .infinity, alignment: .bottom)
                }
            }
        }
        .frame(height: 60)
        .animation(.easeOut(duration: 0.08), value: engine.levels)
    }

    private var placeholderView: some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(Color.gray.opacity(0.1))
            .frame(height: 60)
            .overlay(
                Text("Tap play to start")
                    .font(.caption)
                    .foregroundStyle(.quaternary)
            )
    }

    private var barGradient: LinearGradient {
        LinearGradient(
            colors: [
                Color(red: 0xA0 / 255.0, green: 0x18 / 255.0, blue: 0x18 / 255.0),
                Color(red: 0xA0 / 255.0, green: 0x18 / 255.0, blue: 0x18 / 255.0).opacity(0.6)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}
