@preconcurrency import AVFoundation
import CoreMedia
import Foundation

enum AudioWaveform {
    static func load(from url: URL, sampleCount: Int = 240) async -> [Double] {
        await Task.detached(priority: .utility) {
            do {
                let asset = AVURLAsset(url: url)
                guard let track = try await asset.loadTracks(withMediaType: .audio).first else { return [] }
                let duration = max(try await asset.load(.duration).seconds, 0.001)
                let reader = try AVAssetReader(asset: asset)
                let output = AVAssetReaderTrackOutput(
                    track: track,
                    outputSettings: [
                        AVFormatIDKey: kAudioFormatLinearPCM,
                        AVLinearPCMBitDepthKey: 16,
                        AVLinearPCMIsFloatKey: false,
                        AVLinearPCMIsBigEndianKey: false
                    ]
                )
                reader.add(output)
                guard reader.startReading() else { return [] }
                var peaks = Array(repeating: 0.0, count: sampleCount)
                while let sample = output.copyNextSampleBuffer() {
                    let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds
                    let bucket = min(sampleCount - 1, max(0, Int(time / duration * Double(sampleCount))))
                    guard let buffer = CMSampleBufferGetDataBuffer(sample) else { continue }
                    var length = 0
                    var pointer: UnsafeMutablePointer<Int8>?
                    guard CMBlockBufferGetDataPointer(
                        buffer,
                        atOffset: 0,
                        lengthAtOffsetOut: nil,
                        totalLengthOut: &length,
                        dataPointerOut: &pointer
                    ) == kCMBlockBufferNoErr, let pointer else { continue }
                    let values = UnsafeRawPointer(pointer).assumingMemoryBound(to: Int16.self)
                    var peak = 0.0
                    for index in 0..<(length / MemoryLayout<Int16>.size) {
                        peak = max(peak, Double(abs(Int(values[index]))) / Double(Int16.max))
                    }
                    peaks[bucket] = max(peaks[bucket], peak)
                }
                let maxPeak = peaks.max() ?? 0
                guard maxPeak > 0 else { return peaks }
                return peaks.map { min(1, $0 / maxPeak) }
            } catch {
                return []
            }
        }.value
    }
}
