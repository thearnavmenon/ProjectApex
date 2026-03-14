// SpeechService.swift
// ProjectApex — Services
//
// On-device speech-to-text via SFSpeechRecognizer with a Whisper API fallback.
//
// Architecture (TDD §7.5):
//   • Swift actor — all mutable state is actor-isolated.
//   • startListening() returns AsyncStream<String> of partial transcripts.
//   • stopListening() finalises recognition and returns the final transcript.
//   • On-device SFSpeechRecognizer is tried first.
//   • If average per-segment confidence < 0.8, recorded audio is sent to
//     OpenAI Whisper API (POST /v1/audio/transcriptions, model: whisper-1).
//   • Silence detection: auto-stops after 4 seconds of silence.
//   • Permission denied → graceful degradation; callers check `isAvailable`.
//
// Silence detection:
//   A background Task polls `lastAudioActivityDate` every 0.5 s.
//   If no new audio has arrived for `silenceThresholdSeconds`, the recognition
//   request is finalised exactly as if stopListening() had been called.

import Foundation
import Speech
import AVFoundation

// MARK: - SpeechServiceError

enum SpeechServiceError: LocalizedError {
    case permissionDenied
    case recognizerUnavailable
    case alreadyListening
    case notListening
    case audioEngineFailure(String)
    case whisperAPIError(String)

    var errorDescription: String? {
        switch self {
        case .permissionDenied:        return "Microphone or speech recognition permission denied."
        case .recognizerUnavailable:   return "On-device speech recognizer is not available."
        case .alreadyListening:        return "SpeechService is already actively listening."
        case .notListening:            return "SpeechService is not currently listening."
        case .audioEngineFailure(let d): return "Audio engine error: \(d)"
        case .whisperAPIError(let d):  return "Whisper API error: \(d)"
        }
    }
}

// MARK: - PermissionStatus

enum SpeechPermissionStatus: Sendable {
    case authorized
    case denied
    case notDetermined
}

// MARK: - SpeechService

/// Actor-isolated speech-to-text service.
///
/// Usage:
/// ```swift
/// let service = SpeechService(whisperAPIKey: openAIKey)
/// let status = await service.requestSpeechPermissions()
/// guard status == .authorized else { /* hide mic button */ return }
/// let stream = try await service.startListening()
/// for await partial in stream { liveLabel = partial }
/// let final = try await service.stopListening()
/// ```
actor SpeechService {

    // MARK: - Configuration

    /// Seconds of silence after which recognition auto-stops.
    let silenceThresholdSeconds: TimeInterval

    // MARK: - Private state

    private let whisperAPIKey: String?
    private let urlSession: URLSession

    private var recognizer: SFSpeechRecognizer?
    private var audioEngine: AVAudioEngine?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var silenceMonitorTask: Task<Void, Never>?

    /// Continuation driving the live-partial AsyncStream.
    private var streamContinuation: AsyncStream<String>.Continuation?

    /// Running sum of segment confidences and segment count for fallback decision.
    private var confidenceSum: Double = 0
    private var confidenceCount: Int = 0

    /// Accumulated audio PCM data for Whisper fallback.
    private var audioBuffer: Data = Data()

    /// Timestamp of the most recent audio activity.
    private var lastAudioActivityDate: Date = Date()

    /// Whether we are currently in a listening session.
    private var isListening: Bool = false

    /// Continuation used to resolve `stopListening()` with the final transcript.
    private var stopContinuation: CheckedContinuation<String, Error>?

    /// The best final transcript seen from SFSpeechRecognizer.
    private var bestTranscript: String = ""

    // MARK: - Init

    /// - Parameters:
    ///   - whisperAPIKey: OpenAI API key for Whisper fallback. Pass `nil` to
    ///     disable the fallback (on-device result is always used).
    ///   - silenceThresholdSeconds: Auto-stop after this many seconds of silence.
    ///   - urlSession: Injected for testing; defaults to `.shared`.
    init(
        whisperAPIKey: String? = nil,
        silenceThresholdSeconds: TimeInterval = 4.0,
        urlSession: URLSession = .shared
    ) {
        self.whisperAPIKey = whisperAPIKey
        self.silenceThresholdSeconds = silenceThresholdSeconds
        self.urlSession = urlSession
    }

    // MARK: - Public API

    /// Whether the device supports on-device speech recognition and the user
    /// has been granted permission. Call after `requestSpeechPermissions()`.
    var isAvailable: Bool {
        guard let rec = recognizer else { return false }
        return rec.isAvailable
    }

    /// Requests `SFSpeechRecognizer` authorization and microphone access.
    ///
    /// - Returns: The combined permission status. Both must be `.authorized`
    ///   for `startListening()` to succeed.
    func requestSpeechPermissions() async -> SpeechPermissionStatus {
        // 1. Speech recognition
        let speechStatus = await withCheckedContinuation { (cont: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            SFSpeechRecognizer.requestAuthorization { status in
                cont.resume(returning: status)
            }
        }
        guard speechStatus == .authorized else { return .denied }

        // 2. Microphone
        let micGranted: Bool
        if #available(iOS 17.0, *) {
            micGranted = await AVAudioApplication.requestRecordPermission()
        } else {
            micGranted = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
                AVAudioSession.sharedInstance().requestRecordPermission { granted in
                    cont.resume(returning: granted)
                }
            }
        }
        guard micGranted else { return .denied }

        // Initialise recognizer after permissions are granted
        recognizer = SFSpeechRecognizer(locale: Locale.current)
        return .authorized
    }

    /// Begins live speech recognition.
    ///
    /// - Returns: An `AsyncStream<String>` of partial transcripts. The stream
    ///   finishes when `stopListening()` is called or silence is detected.
    /// - Throws: `SpeechServiceError` if permissions are denied, recognition
    ///   is unavailable, or the audio engine fails to start.
    func startListening() throws -> AsyncStream<String> {
        guard !isListening else { throw SpeechServiceError.alreadyListening }

        guard let recognizer, recognizer.isAvailable else {
            throw SpeechServiceError.recognizerUnavailable
        }

        // Reset per-session state
        confidenceSum = 0
        confidenceCount = 0
        audioBuffer = Data()
        bestTranscript = ""
        lastAudioActivityDate = Date()
        isListening = true

        // Configure audio session
        let audioSession = AVAudioSession.sharedInstance()
        do {
            try audioSession.setCategory(.record, mode: .measurement, options: .duckOthers)
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            isListening = false
            throw SpeechServiceError.audioEngineFailure(error.localizedDescription)
        }

        // Build recognition request
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        // Request on-device recognition when possible for low-latency
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        recognitionRequest = request

        // Create and start audio engine
        let engine = AVAudioEngine()
        audioEngine = engine
        let inputNode = engine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self] buffer, _ in
            guard let self else { return }
            request.append(buffer)
            // Capture raw PCM for potential Whisper fallback
            Task { await self.appendAudioBuffer(buffer) }
        }

        do {
            engine.prepare()
            try engine.start()
        } catch {
            stopAudioEngine()
            isListening = false
            throw SpeechServiceError.audioEngineFailure(error.localizedDescription)
        }

        // Build stream + kick off recognition task
        let stream = AsyncStream<String> { continuation in
            self.streamContinuation = continuation
        }

        // Start recognition task
        let task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            Task { await self.handleRecognitionResult(result, error: error) }
        }
        recognitionTask = task

        // Start silence monitor
        startSilenceMonitor()

        return stream
    }

    /// Stops listening and returns the final transcript.
    ///
    /// If the average on-device confidence is below 0.8 **and** a Whisper API
    /// key is configured, the recorded audio is sent to Whisper and its result
    /// is returned instead.
    ///
    /// - Returns: The final transcript string (may be empty if nothing was spoken).
    /// - Throws: `SpeechServiceError.notListening` if not currently recording.
    func stopListening() async throws -> String {
        guard isListening else { throw SpeechServiceError.notListening }
        return try await withCheckedThrowingContinuation { cont in
            self.stopContinuation = cont
            self.finaliseRecognition()
        }
    }

    // MARK: - Private: Audio / Recognition helpers

    private func appendAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        lastAudioActivityDate = Date()
        // Collect raw float samples for Whisper (16-bit PCM conversion done at upload time)
        guard let channelData = buffer.floatChannelData?[0] else { return }
        let frameCount = Int(buffer.frameLength)
        let samples = Array(UnsafeBufferPointer(start: channelData, count: frameCount))
        // Convert Float32 → Int16 → Data
        var int16Samples = samples.map { sample -> Int16 in
            let clamped = max(-1.0, min(1.0, sample))
            return Int16(clamped * 32767)
        }
        audioBuffer.append(Data(bytes: &int16Samples, count: int16Samples.count * MemoryLayout<Int16>.size))
    }

    private func handleRecognitionResult(_ result: SFSpeechRecognitionResult?, error: Error?) {
        if let result {
            let bestAlternative = result.bestTranscription
            let transcript = bestAlternative.formattedString
            bestTranscript = transcript

            // Accumulate confidence across segments
            for segment in bestAlternative.segments {
                confidenceSum += Double(segment.confidence)
                confidenceCount += 1
            }

            streamContinuation?.yield(transcript)

            if result.isFinal {
                finishSession(finalTranscript: transcript)
            }
        }

        if let error {
            // Domain NSCocoaErrorDomain code 1101 = "No speech detected" — treat as silence
            let isNoSpeech = (error as NSError).code == 1101
            if !isNoSpeech {
                streamContinuation?.finish()
                stopContinuation?.resume(returning: bestTranscript)
                stopContinuation = nil
                isListening = false
            }
        }
    }

    private func finaliseRecognition() {
        silenceMonitorTask?.cancel()
        silenceMonitorTask = nil
        recognitionRequest?.endAudio()
    }

    private func finishSession(finalTranscript: String) {
        stopAudioEngine()
        streamContinuation?.finish()
        streamContinuation = nil
        isListening = false

        let avgConfidence = confidenceCount > 0 ? confidenceSum / Double(confidenceCount) : 1.0
        let capturedAudio = audioBuffer
        let capturedTranscript = finalTranscript
        let key = whisperAPIKey
        let session = urlSession

        guard avgConfidence < 0.8, let apiKey = key, !capturedAudio.isEmpty else {
            stopContinuation?.resume(returning: capturedTranscript)
            stopContinuation = nil
            return
        }

        // Low confidence → Whisper fallback
        let cont = stopContinuation
        stopContinuation = nil
        Task.detached {
            do {
                let whisperResult = try await Self.callWhisper(
                    audioData: capturedAudio,
                    apiKey: apiKey,
                    urlSession: session
                )
                cont?.resume(returning: whisperResult)
            } catch {
                // Whisper failed — fall back to on-device result
                cont?.resume(returning: capturedTranscript)
            }
        }
    }

    private func stopAudioEngine() {
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: - Private: Silence Monitor

    private func startSilenceMonitor() {
        let threshold = silenceThresholdSeconds
        silenceMonitorTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 s poll
                guard let self else { return }
                let elapsed = await self.elapsedSinceLastActivity()
                if elapsed >= threshold {
                    await self.triggerSilenceStop()
                    return
                }
            }
        }
    }

    private func elapsedSinceLastActivity() -> TimeInterval {
        Date().timeIntervalSince(lastAudioActivityDate)
    }

    private func triggerSilenceStop() {
        guard isListening else { return }
        silenceMonitorTask = nil
        finaliseRecognition()
        // If recognition task doesn't fire a final result quickly, resolve directly
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 s grace
            guard let self else { return }
            await self.resolveIfStillPending()
        }
    }

    private func resolveIfStillPending() {
        guard let cont = stopContinuation else { return }
        stopContinuation = nil
        stopAudioEngine()
        streamContinuation?.finish()
        streamContinuation = nil
        isListening = false
        cont.resume(returning: bestTranscript)
    }

    // MARK: - Whisper API

    /// POSTs raw PCM audio to OpenAI Whisper transcription endpoint.
    ///
    /// Audio is sent as a WAV-wrapped payload using multipart/form-data.
    /// Model: `whisper-1`.
    private static func callWhisper(
        audioData: Data,
        apiKey: String,
        urlSession: URLSession
    ) async throws -> String {
        let url = URL(string: "https://api.openai.com/v1/audio/transcriptions")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let boundary = "Boundary-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        let crlf = "\r\n"

        // model field
        body.append("--\(boundary)\(crlf)".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"model\"\(crlf)\(crlf)".data(using: .utf8)!)
        body.append("whisper-1\(crlf)".data(using: .utf8)!)

        // file field — wrap PCM in a minimal WAV container so Whisper accepts it
        let wavData = wrapPCMInWAV(pcmData: audioData, sampleRate: 44100, channels: 1, bitsPerSample: 16)
        body.append("--\(boundary)\(crlf)".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\(crlf)".data(using: .utf8)!)
        body.append("Content-Type: audio/wav\(crlf)\(crlf)".data(using: .utf8)!)
        body.append(wavData)
        body.append(crlf.data(using: .utf8)!)

        body.append("--\(boundary)--\(crlf)".data(using: .utf8)!)
        request.httpBody = body

        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let bodyStr = String(data: data, encoding: .utf8) ?? "<binary>"
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw SpeechServiceError.whisperAPIError("HTTP \(code): \(bodyStr.prefix(200))")
        }

        // Response: {"text": "…"}
        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let text = json["text"] as? String
        else {
            throw SpeechServiceError.whisperAPIError("Unexpected response format.")
        }
        return text
    }

    /// Wraps raw signed 16-bit PCM bytes in a canonical WAV RIFF header.
    private static func wrapPCMInWAV(
        pcmData: Data,
        sampleRate: UInt32,
        channels: UInt16,
        bitsPerSample: UInt16
    ) -> Data {
        var wav = Data()
        let dataSize = UInt32(pcmData.count)
        let byteRate = sampleRate * UInt32(channels) * UInt32(bitsPerSample) / 8
        let blockAlign = channels * bitsPerSample / 8

        func appendLE<T: FixedWidthInteger>(_ value: T) {
            var v = value.littleEndian
            wav.append(Data(bytes: &v, count: MemoryLayout<T>.size))
        }

        wav.append("RIFF".data(using: .utf8)!)
        appendLE(UInt32(36 + dataSize))           // ChunkSize
        wav.append("WAVE".data(using: .utf8)!)
        wav.append("fmt ".data(using: .utf8)!)
        appendLE(UInt32(16))                       // Subchunk1Size (PCM)
        appendLE(UInt16(1))                        // AudioFormat = PCM
        appendLE(channels)
        appendLE(sampleRate)
        appendLE(byteRate)
        appendLE(blockAlign)
        appendLE(bitsPerSample)
        wav.append("data".data(using: .utf8)!)
        appendLE(dataSize)
        wav.append(pcmData)
        return wav
    }
}
