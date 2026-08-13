@preconcurrency import AVFoundation
import Foundation

enum ClickSoundAsset {
    static func makeTemporary() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "captura-click-\(UUID().uuidString).caf")
        let sampleRate = 48_000.0
        let frameCount = AVAudioFrameCount(sampleRate * 0.065)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            throw ExportError.compositionFailed("Could not allocate the click sound buffer.")
        }
        buffer.frameLength = frameCount
        for channel in 0..<Int(format.channelCount) {
            guard let samples = buffer.floatChannelData?[channel] else { continue }
            for frame in 0..<Int(frameCount) {
                let time = Double(frame) / sampleRate
                let attack = min(1, time / 0.002)
                let decay = exp(-time * 68)
                let body = sin(2 * .pi * 1_450 * time) * 0.72
                let snap = sin(2 * .pi * 3_400 * time) * 0.28
                samples[frame] = Float((body + snap) * attack * decay)
            }
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
        return url
    }
}
