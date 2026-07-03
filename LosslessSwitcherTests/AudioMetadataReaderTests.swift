//
//  AudioMetadataReaderTests.swift
//  LosslessSwitcherTests
//
//  Verifies AudioMetadataReader reads sample rates from generated WAV
//  fixtures and returns nil for non-audio files.
//

import XCTest
import AVFoundation
@testable import LosslessSwitcher

final class AudioMetadataReaderTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AudioMetadataReaderTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        tempDir = nil
        super.tearDown()
    }

    func testReadsSampleRateFromGeneratedWavFixture() throws {
        let wavURL = tempDir.appendingPathComponent("fixture-44100.wav")
        try writeSilentWAV(to: wavURL, sampleRate: 44100, channels: 2, bitsPerChannel: 16)

        let metadata = AudioMetadataReader.read(url: wavURL)
        XCTAssertNotNil(metadata, "Expected non-nil metadata for a valid WAV fixture")
        XCTAssertEqual(metadata?.sampleRate ?? 0, 44100, accuracy: 0.001,
                       "Expected 44100 Hz sample rate")
        XCTAssertNotNil(metadata?.bitDepth, "Expected non-nil bit depth for 16-bit WAV")
        XCTAssertEqual(metadata?.bitDepth, 16)
    }

    func testReadsSampleRateFrom96kWavFixture() throws {
        let wavURL = tempDir.appendingPathComponent("fixture-96000.wav")
        try writeSilentWAV(to: wavURL, sampleRate: 96000, channels: 2, bitsPerChannel: 24)

        let metadata = AudioMetadataReader.read(url: wavURL)
        XCTAssertNotNil(metadata)
        XCTAssertEqual(metadata?.sampleRate ?? 0, 96000, accuracy: 0.001)
        XCTAssertEqual(metadata?.bitDepth, 24)
    }

    func testReturnsNilForUnsupportedTextFile() throws {
        let textURL = tempDir.appendingPathComponent("not-audio.txt")
        try "this is not audio".write(to: textURL, atomically: true, encoding: .utf8)

        let metadata = AudioMetadataReader.read(url: textURL)
        XCTAssertNil(metadata, "Expected nil for a plain text file")
    }

    func testReturnsNilForMissingFile() {
        let missingURL = tempDir.appendingPathComponent("does-not-exist.wav")
        let metadata = AudioMetadataReader.read(url: missingURL)
        XCTAssertNil(metadata, "Expected nil for a non-existent file")
    }

    func testReturnsNilForDirectory() {
        let metadata = AudioMetadataReader.read(url: tempDir)
        XCTAssertNil(metadata, "Expected nil for a directory URL")
    }

    // MARK: - Helpers

    /// Writes a short silent PCM WAV file at the requested sample rate using
    /// AVAudioFile, so tests don't depend on external fixtures.
    private func writeSilentWAV(
        to url: URL,
        sampleRate: Double,
        channels: AVAudioChannelCount,
        bitsPerChannel: UInt32
    ) throws {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: sampleRate,
            channels: channels,
            interleaved: false
        )!

        // AVAudioFile writes WAV when the extension is .wav.
        let file = try AVAudioFile(forWriting: url, settings: format.settings)

        let frameCount = AVAudioFrameCount(sampleRate * 0.25) // 0.25s of silence
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            XCTFail("Failed to allocate PCM buffer")
            return
        }
        buffer.frameLength = frameCount
        // Zero-filled buffer = silence. Int16 format already zeroed by init.

        try file.write(from: buffer)
    }
}
