@preconcurrency import Speech
import Foundation

enum LocalTranscriptionError: LocalizedError {
    case permissionDenied
    case unavailable
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .permissionDenied: "Speech recognition permission was not granted."
        case .unavailable: "On-device speech recognition is unavailable for the current language."
        case let .failed(message): "Transcription failed: \(message)"
        }
    }
}

final class LocalTranscriber: @unchecked Sendable {
    private final class Completion: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<[CaptionCue], Error>?

        init(_ continuation: CheckedContinuation<[CaptionCue], Error>) {
            self.continuation = continuation
        }

        func finish(_ result: Result<[CaptionCue], Error>) {
            let continuation = lock.withLock { () -> CheckedContinuation<[CaptionCue], Error>? in
                defer { self.continuation = nil }
                return self.continuation
            }
            continuation?.resume(with: result)
        }
    }

    func transcribe(url: URL, locale: Locale = .current) async throws -> [CaptionCue] {
        guard await requestPermission() else { throw LocalTranscriptionError.permissionDenied }
        guard let recognizer = SFSpeechRecognizer(locale: locale),
              recognizer.isAvailable,
              recognizer.supportsOnDeviceRecognition else {
            throw LocalTranscriptionError.unavailable
        }
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false
        request.taskHint = .dictation

        return try await withCheckedThrowingContinuation { continuation in
            let completion = Completion(continuation)
            recognizer.recognitionTask(with: request) { result, error in
                if let error {
                    completion.finish(.failure(LocalTranscriptionError.failed(error.localizedDescription)))
                } else if let result, result.isFinal {
                    completion.finish(.success(Self.makeCues(from: result.bestTranscription.segments)))
                }
            }
        }
    }

    private func requestPermission() async -> Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: return true
        case .denied, .restricted: return false
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { status in
                    continuation.resume(returning: status == .authorized)
                }
            }
        @unknown default: return false
        }
    }

    private static func makeCues(from segments: [SFTranscriptionSegment]) -> [CaptionCue] {
        var cues: [CaptionCue] = []
        var words: [String] = []
        var start = 0.0
        var end = 0.0
        for segment in segments {
            if words.isEmpty { start = segment.timestamp }
            words.append(segment.substring)
            end = segment.timestamp + segment.duration
            if words.count >= 7 || end - start >= 3.2 {
                cues.append(CaptionCue(startTime: start, endTime: end, text: words.joined(separator: " ")))
                words.removeAll(keepingCapacity: true)
            }
        }
        if !words.isEmpty {
            cues.append(CaptionCue(startTime: start, endTime: max(end, start + 0.8), text: words.joined(separator: " ")))
        }
        return cues
    }
}
