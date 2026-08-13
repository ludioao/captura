import AVFoundation
import Foundation
import MediaToolbox

enum VoiceProcessingAudioTap {
    private final class Context {
        let voiceEnhancement: Bool
        let noiseReduction: Bool
        var previousInput: [Float] = []
        var previousOutput: [Float] = []
        var envelope: [Float] = []
        var highPassCoefficient: Float = 0.985

        init(voiceEnhancement: Bool, noiseReduction: Bool) {
            self.voiceEnhancement = voiceEnhancement
            self.noiseReduction = noiseReduction
        }

        func prepare(channels: Int, sampleRate: Double) {
            previousInput = Array(repeating: 0, count: channels)
            previousOutput = Array(repeating: 0, count: channels)
            envelope = Array(repeating: 0, count: channels)
            let cutoff = 85.0
            let rc = 1 / (2 * Double.pi * cutoff)
            let dt = 1 / max(sampleRate, 1)
            highPassCoefficient = Float(rc / (rc + dt))
        }
    }

    static func make(voiceEnhancement: Bool, noiseReduction: Bool) throws -> MTAudioProcessingTap {
        let context = Context(voiceEnhancement: voiceEnhancement, noiseReduction: noiseReduction)
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: Unmanaged.passRetained(context).toOpaque(),
            init: { _, clientInfo, storageOut in storageOut.pointee = clientInfo },
            finalize: { tap in
                let storage = MTAudioProcessingTapGetStorage(tap)
                Unmanaged<Context>.fromOpaque(storage).release()
            },
            prepare: { tap, _, format in
                let storage = MTAudioProcessingTapGetStorage(tap)
                Unmanaged<Context>.fromOpaque(storage).takeUnretainedValue().prepare(
                    channels: Int(format.pointee.mChannelsPerFrame),
                    sampleRate: format.pointee.mSampleRate
                )
            },
            unprepare: { _ in },
            process: { tap, requestedFrames, flags, bufferList, producedFrames, producedFlags in
                var sourceFlags = MTAudioProcessingTapFlags()
                var sourceFrames: CMItemCount = 0
                let status = MTAudioProcessingTapGetSourceAudio(
                    tap,
                    requestedFrames,
                    bufferList,
                    &sourceFlags,
                    nil,
                    &sourceFrames
                )
                guard status == noErr else {
                    producedFrames.pointee = 0
                    return
                }
                producedFrames.pointee = sourceFrames
                producedFlags.pointee = sourceFlags | flags
                let storage = MTAudioProcessingTapGetStorage(tap)
                let context = Unmanaged<Context>.fromOpaque(storage).takeUnretainedValue()
                let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
                for (channel, audioBuffer) in buffers.enumerated() {
                    guard let data = audioBuffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                    let sampleCount = min(Int(sourceFrames), Int(audioBuffer.mDataByteSize) / MemoryLayout<Float>.size)
                    let stateIndex = min(channel, max(0, context.previousInput.count - 1))
                    guard !context.previousInput.isEmpty else { continue }
                    for index in 0..<sampleCount {
                        var sample = data[index]
                        if context.voiceEnhancement {
                            let highPassed = context.highPassCoefficient * (
                                context.previousOutput[stateIndex] + sample - context.previousInput[stateIndex]
                            )
                            context.previousInput[stateIndex] = sample
                            context.previousOutput[stateIndex] = highPassed
                            sample = tanh(highPassed * 1.65) / tanh(1.65) * 0.96
                        }
                        if context.noiseReduction {
                            let magnitude = abs(sample)
                            context.envelope[stateIndex] = max(
                                magnitude,
                                context.envelope[stateIndex] * 0.996
                            )
                            let floor: Float = 0.012
                            let gain = min(max((context.envelope[stateIndex] - floor) / floor, 0.08), 1)
                            sample *= gain
                        }
                        data[index] = sample
                    }
                }
            }
        )
        var tap: MTAudioProcessingTap?
        let status = MTAudioProcessingTapCreate(
            kCFAllocatorDefault,
            &callbacks,
            kMTAudioProcessingTapCreationFlag_PostEffects,
            &tap
        )
        guard status == noErr, let tap else {
            throw ExportError.compositionFailed("Could not initialize voice processing (\(status)).")
        }
        return tap
    }
}
