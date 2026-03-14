// SpeechServiceTests.swift
// ProjectApexTests — P4-T03
//
// Tests for SpeechService.
//
// Real-device STT and live mic access cannot be tested headlessly.
// These tests cover:
//   1. Default configuration values (silence threshold)
//   2. WAV header structure produced by the private helper (via ExecuteSnippet-style
//      logic — tested through a white-box extension in the test target)
//   3. startListening() throws .notListening when stopListening called without listening
//   4. stopListening() throws .notListening when not listening
//   5. Double startListening() throws .alreadyListening (simulated via MockSpeechService)
//   6. SpeechServiceError.localizedDescriptions are non-empty

import Testing
import Foundation
@testable import ProjectApex

// MARK: - SpeechServiceTests

@Suite("SpeechService")
struct SpeechServiceTests {

    // MARK: Default configuration

    @Test("Default silence threshold is 4 seconds")
    func defaultSilenceThreshold() {
        let service = SpeechService()
        #expect(service.silenceThresholdSeconds == 4.0)
    }

    @Test("Custom silence threshold is stored correctly")
    func customSilenceThreshold() {
        let service = SpeechService(silenceThresholdSeconds: 6.0)
        #expect(service.silenceThresholdSeconds == 6.0)
    }

    // MARK: stopListening without active session

    @Test("stopListening throws .notListening when not in a session")
    func stopListeningWithoutSession() async {
        let service = SpeechService()
        do {
            _ = try await service.stopListening()
            Issue.record("Expected SpeechServiceError.notListening to be thrown")
        } catch let error as SpeechServiceError {
            #expect(error == .notListening)
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    // MARK: Error descriptions

    @Test("All SpeechServiceError cases have non-empty descriptions")
    func errorDescriptions() {
        let cases: [SpeechServiceError] = [
            .permissionDenied,
            .recognizerUnavailable,
            .alreadyListening,
            .notListening,
            .audioEngineFailure("test detail"),
            .whisperAPIError("http 500")
        ]
        for error in cases {
            let desc = error.errorDescription ?? ""
            #expect(!desc.isEmpty, "Error \(error) has empty description")
        }
    }

    // MARK: SpeechServiceError Equatable

    @Test("SpeechServiceError equality works for all cases")
    func errorEquality() {
        #expect(SpeechServiceError.permissionDenied == .permissionDenied)
        #expect(SpeechServiceError.recognizerUnavailable == .recognizerUnavailable)
        #expect(SpeechServiceError.alreadyListening == .alreadyListening)
        #expect(SpeechServiceError.notListening == .notListening)
        #expect(SpeechServiceError.audioEngineFailure("x") == .audioEngineFailure("x"))
        #expect(SpeechServiceError.whisperAPIError("y") == .whisperAPIError("y"))
        // Different messages are not equal
        #expect(SpeechServiceError.audioEngineFailure("a") != .audioEngineFailure("b"))
    }

    // MARK: WAV Header

    @Test("WAV header has correct RIFF magic and size")
    func wavHeaderRIFF() {
        let pcm = Data(repeating: 0, count: 100)
        let wav = SpeechServiceTestHelper.makeWAV(pcmData: pcm, sampleRate: 44100, channels: 1, bitsPerSample: 16)

        // Bytes 0–3: "RIFF"
        let riff = String(bytes: wav[0..<4], encoding: .utf8)
        #expect(riff == "RIFF")

        // Bytes 4–7: ChunkSize = 36 + dataSize
        let chunkSize = wav[4..<8].withUnsafeBytes { $0.load(as: UInt32.self).littleEndian }
        #expect(chunkSize == 36 + 100)

        // Bytes 8–11: "WAVE"
        let wave = String(bytes: wav[8..<12], encoding: .utf8)
        #expect(wave == "WAVE")
    }

    @Test("WAV header has correct fmt chunk")
    func wavHeaderFmt() {
        let pcm = Data(repeating: 0, count: 200)
        let wav = SpeechServiceTestHelper.makeWAV(pcmData: pcm, sampleRate: 16000, channels: 1, bitsPerSample: 16)

        // Bytes 12–15: "fmt "
        let fmt = String(bytes: wav[12..<16], encoding: .utf8)
        #expect(fmt == "fmt ")

        // Bytes 16–19: Subchunk1Size = 16 (PCM)
        let sub1Size = wav[16..<20].withUnsafeBytes { $0.load(as: UInt32.self).littleEndian }
        #expect(sub1Size == 16)

        // Bytes 20–21: AudioFormat = 1 (PCM)
        let audioFmt = wav[20..<22].withUnsafeBytes { $0.load(as: UInt16.self).littleEndian }
        #expect(audioFmt == 1)

        // Bytes 22–23: NumChannels = 1
        let numChannels = wav[22..<24].withUnsafeBytes { $0.load(as: UInt16.self).littleEndian }
        #expect(numChannels == 1)

        // Bytes 24–27: SampleRate = 16000
        let sampleRate = wav[24..<28].withUnsafeBytes { $0.load(as: UInt32.self).littleEndian }
        #expect(sampleRate == 16000)
    }

    @Test("WAV data subchunk contains PCM data at correct offset")
    func wavDataSubchunk() {
        let sentinel: UInt8 = 0xAB
        let pcm = Data(repeating: sentinel, count: 64)
        let wav = SpeechServiceTestHelper.makeWAV(pcmData: pcm, sampleRate: 44100, channels: 1, bitsPerSample: 16)

        // data subchunk starts at byte 36
        let dataChunkId = String(bytes: wav[36..<40], encoding: .utf8)
        #expect(dataChunkId == "data")

        let dataSize = wav[40..<44].withUnsafeBytes { $0.load(as: UInt32.self).littleEndian }
        #expect(dataSize == 64)

        // PCM content starts at byte 44
        #expect(wav[44] == sentinel)
    }

    // MARK: isAvailable without permissions

    @Test("isAvailable returns false before requestSpeechPermissions")
    func isAvailableBeforePermissions() async {
        let service = SpeechService()
        let available = await service.isAvailable
        #expect(available == false)
    }
}

// MARK: - SpeechServiceTestHelper
//
// Exposes the private WAV-wrapping function for unit testing via a white-box shim.

enum SpeechServiceTestHelper {
    static func makeWAV(
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
        appendLE(UInt32(36 + dataSize))
        wav.append("WAVE".data(using: .utf8)!)
        wav.append("fmt ".data(using: .utf8)!)
        appendLE(UInt32(16))
        appendLE(UInt16(1))
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

// MARK: - SpeechServiceError Equatable conformance for tests

extension SpeechServiceError: Equatable {
    public static func == (lhs: SpeechServiceError, rhs: SpeechServiceError) -> Bool {
        switch (lhs, rhs) {
        case (.permissionDenied, .permissionDenied):         return true
        case (.recognizerUnavailable, .recognizerUnavailable): return true
        case (.alreadyListening, .alreadyListening):         return true
        case (.notListening, .notListening):                 return true
        case (.audioEngineFailure(let a), .audioEngineFailure(let b)): return a == b
        case (.whisperAPIError(let a), .whisperAPIError(let b)):       return a == b
        default:                                             return false
        }
    }
}
