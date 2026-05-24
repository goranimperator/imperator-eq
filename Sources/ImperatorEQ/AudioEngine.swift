import AVFoundation
import Accelerate

@MainActor
final class AudioEngine: ObservableObject {
    @Published var levels: [Float] = Array(repeating: 0.0, count: 32)
    @Published var isRunning = false

    private var engine: AVAudioEngine?
    private var tap: AVAudioNodeTapBlock?

    func start() {
        guard !isRunning else { return }

        let engine = AVAudioEngine()
        self.engine = engine

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)

        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.processBuffer(buffer)
        }

        do {
            try engine.start()
            isRunning = true
        } catch {
            isRunning = false
        }
    }

    func stop() {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        isRunning = false
        levels = Array(repeating: 0.0, count: 32)
    }

    private func processBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData else { return }
        let frameCount = Int(buffer.frameLength)
        let data = Array(UnsafeBufferPointer(start: channelData[0], count: frameCount))

        let bandCount = 32
        let bandSize = frameCount / bandCount
        var newLevels = [Float](repeating: 0.0, count: bandCount)

        for i in 0..<bandCount {
            let start = i * bandSize
            let end = min(start + bandSize, frameCount)
            var sum: Float = 0
            for j in start..<end {
                sum += abs(data[j])
            }
            let avg = sum / Float(end - start)
            newLevels[i] = min(avg * 5.0, 1.0)
        }

        Task { @MainActor in
            self.levels = newLevels
        }
    }
}
