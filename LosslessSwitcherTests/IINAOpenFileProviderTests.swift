//
//  IINAOpenFileProviderTests.swift
//  LosslessSwitcherTests
//
//  Tests the lsof output parser (pure seam) and the provider's duplicate
//  suppression behavior. These tests do NOT require IINA to be installed or
//  running — they use fixture lsof output strings and the reducer directly.
//

import XCTest
import Combine
import AVFoundation
@testable import LosslessSwitcher

final class IINAOpenFileProviderTests: XCTestCase {

    private var cancellables: Set<AnyCancellable> = []
    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        cancellables.removeAll()
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("IINAProviderTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        tempDir = nil
        super.tearDown()
    }

    // MARK: - LsofMediaPathParser

    func testLsofParserKeepsFlacAndDropsAppResources() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let fixture = """
        p12345
        f1234
        n/Applications/IINA.app/Contents/Resources/something.flac
        n/Users/test/Music/album/track.flac
        n/Library/Application Support/com.colliderli.iina/cache.dat
        """
        let urls = LsofMediaPathParser.mediaPaths(from: fixture, homeDirectory: home)
        XCTAssertEqual(urls.count, 1, "Only the user-track FLAC should survive; app resources must be dropped")
        XCTAssertTrue(urls.first?.path.hasSuffix("track.flac") ?? false)
    }

    func testLsofParserKeepsMostRelevantMediaExtensions() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let fixture = """
        p12345
        n/Users/test/song.flac
        n/Users/test/song.wav
        n/Users/test/song.aiff
        n/Users/test/song.m4a
        n/Users/test/song.mp3
        n/Users/test/song.ogg
        n/Users/test/song.opus
        n/Users/test/song.mp4
        n/Users/test/song.mkv
        n/Users/test/song.mov
        n/Users/test/subtitle.srt
        n/Users/test/notes.txt
        n/Users/test/cover.jpg
        """
        let urls = LsofMediaPathParser.mediaPaths(from: fixture, homeDirectory: home)
        let exts = urls.map { ($0.path as NSString).pathExtension.lowercased() }
        XCTAssertEqual(exts.sorted(), ["aiff", "flac", "m4a", "mkv", "mov", "mp3", "mp4", "ogg", "opus", "wav"].sorted(),
                       "Parser must keep all supported media extensions and drop subtitles/text/images")
    }

    func testLsofParserDeduplicatesPaths() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let fixture = """
        p12345
        n/Users/test/track.flac
        n/Users/test/track.flac
        n/Users/test/track.flac
        """
        let urls = LsofMediaPathParser.mediaPaths(from: fixture, homeDirectory: home)
        XCTAssertEqual(urls.count, 1, "Duplicate paths must be collapsed to a single URL")
    }

    func testLsofParserExpandsTildePrefixedPaths() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let fixture = """
        p12345
        n~/Music/track.flac
        """
        let urls = LsofMediaPathParser.mediaPaths(from: fixture, homeDirectory: home)
        XCTAssertEqual(urls.count, 1)
        XCTAssertTrue(urls.first?.path.hasPrefix(home.path) ?? false,
                      "Tilde-prefixed paths must be expanded against the provided home directory")
    }

    // MARK: - Provider candidate emission + duplicate suppression (Task 9)

    func testProviderCandidateUsesMetadataReaderResult() throws {
        // Generate a real WAV fixture so AudioMetadataReader returns a real rate.
        // This verifies the metadata path the provider would use to build a
        // DetectionCandidate, without starting the provider's timer (which
        // requires IINA to be running and would be non-deterministic in CI).
        let wavURL = tempDir.appendingPathComponent("provider-test-44100.wav")
        try writeSilentWAV(to: wavURL, sampleRate: 44100)

        let metadata = AudioMetadataReader.read(url: wavURL)
        XCTAssertEqual(metadata?.sampleRate ?? 0, 44100, accuracy: 0.001,
                       "Provider would emit this rate for the open file")
        XCTAssertNotNil(metadata?.bitDepth,
                       "Provider would include bit depth in the candidate")

        // Verify the provider can be constructed without side effects.
        let provider = IINAOpenFileProvider()
        XCTAssertEqual(provider.identifier, "IINAOpenFileProvider")
    }

    func testRepeatedSameIINAStatDoesNotTriggerRepeatedGeneration() {
        // Task 9: verifies the reducer suppresses repeated same-rate
        // lower-or-equal-confidence candidates so latestStats does not flash.
        var reducer = DetectionCandidateReducer()
        let now = Date()
        let stat = CMPlayerStats(sampleRate: 44100, bitDepth: 16, date: now, priority: 7, processName: "IINA", trackName: "track.flac")
        let candidate = DetectionCandidate(
            stats: stat,
            sourceKind: .iinaLocalFile,
            confidence: 7,
            expiresAt: now.addingTimeInterval(4),
            diagnostic: "IINA local file"
        )

        XCTAssertTrue(reducer.shouldAccept(candidate, now: now), "First candidate must be accepted")
        // Identical candidate with the same confidence and rate — must be rejected.
        XCTAssertFalse(reducer.shouldAccept(candidate, now: now), "Identical re-emission must be suppressed")
        XCTAssertFalse(reducer.shouldAccept(candidate, now: now), "Repeated identical emission must stay suppressed")
    }

    func testReducerAcceptsHigherConfidenceReplacement() {
        var reducer = DetectionCandidateReducer()
        let now = Date()
        let lowPriority = DetectionCandidate(
            stats: CMPlayerStats(sampleRate: 44100, bitDepth: 24, date: now, priority: 2, processName: "CoreMedia"),
            sourceKind: .coreMediaLog,
            confidence: 2,
            expiresAt: now.addingTimeInterval(4),
            diagnostic: "low"
        )
        let highPriority = DetectionCandidate(
            stats: CMPlayerStats(sampleRate: 44100, bitDepth: 16, date: now, priority: 7, processName: "IINA"),
            sourceKind: .iinaLocalFile,
            confidence: 7,
            expiresAt: now.addingTimeInterval(4),
            diagnostic: "high"
        )

        XCTAssertTrue(reducer.shouldAccept(lowPriority, now: now))
        XCTAssertTrue(reducer.shouldAccept(highPriority, now: now),
                      "Higher-confidence candidate must replace the accepted one even at the same rate")
        XCTAssertFalse(reducer.shouldAccept(highPriority, now: now),
                       "After accepting the higher-confidence candidate, a duplicate must be suppressed")
    }

    func testReducerRejectsExpiredCandidate() {
        var reducer = DetectionCandidateReducer()
        let now = Date()
        let expired = DetectionCandidate(
            stats: CMPlayerStats(sampleRate: 44100, bitDepth: 16, date: now, priority: 7),
            sourceKind: .iinaLocalFile,
            confidence: 7,
            expiresAt: now.addingTimeInterval(-1), // already expired
            diagnostic: "stale"
        )
        XCTAssertFalse(reducer.shouldAccept(expired, now: now), "Expired candidate must be rejected")
    }

    func testReducerAcceptsNewerDifferentRate() {
        var reducer = DetectionCandidateReducer()
        let now = Date()
        let first = DetectionCandidate(
            stats: CMPlayerStats(sampleRate: 44100, bitDepth: 16, date: now, priority: 7),
            sourceKind: .iinaLocalFile,
            confidence: 7,
            expiresAt: now.addingTimeInterval(4),
            diagnostic: "44.1k"
        )
        let second = DetectionCandidate(
            stats: CMPlayerStats(sampleRate: 96000, bitDepth: 24, date: now.addingTimeInterval(1), priority: 7),
            sourceKind: .iinaLocalFile,
            confidence: 7,
            expiresAt: now.addingTimeInterval(4),
            diagnostic: "96k"
        )

        XCTAssertTrue(reducer.shouldAccept(first, now: now))
        XCTAssertTrue(reducer.shouldAccept(second, now: now),
                       "Newer candidate with a materially different rate must be accepted")
    }

    // MARK: - Helpers

    private func writeSilentWAV(to url: URL, sampleRate: Double) throws {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: sampleRate,
            channels: 2,
            interleaved: false
        )!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let frameCount = AVAudioFrameCount(sampleRate * 0.25)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            XCTFail("Failed to allocate PCM buffer")
            return
        }
        buffer.frameLength = frameCount
        try file.write(from: buffer)
    }
}
