//
//  BrowserLogParserTests.swift
//  LosslessSwitcherTests
//
//  Verifies BrowserCoreMediaParser only emits stats from known browser process
//  names, accepts credible sample-rate lines, and ignores lines without a
//  parseable rate.
//

import XCTest
@testable import LosslessSwitcher

final class BrowserLogParserTests: XCTestCase {

    private let parser = BrowserCoreMediaParser()

    // MARK: - Positive cases: browser lines with a sample rate

    func testBrowserCoreMediaSampleRateParses() {
        // Simulate a Chrome CoreMedia fpfs line with [SampleRate 48000].
        let line = "2026-07-04 09:00:00.000 Chrome[1234:5678] [fpfs_ReportAudioPlaybackThroughFigLog] [SampleRate 48000] [BitDepth 16]"
        let stat = parser.parse(line: line, currentTrackName: nil)

        XCTAssertNotNil(stat, "Expected a stat for a browser line with [SampleRate 48000]")
        XCTAssertEqual(stat?.sampleRate, 48000)
        XCTAssertEqual(stat?.priority, 3)
        XCTAssertEqual(stat?.processName, "Chrome")
    }

    func testBrowserAudioQueueSampleRateParses() {
        // Simulate a Safari Creating AudioQueue line with sampleRate:44100.0.
        let line = "2026-07-04 09:00:00.000 Safari[1234:5678] Creating AudioQueue sampleRate:44100.0"
        let stat = parser.parse(line: line, currentTrackName: nil)

        XCTAssertNotNil(stat, "Expected a stat for a Safari AudioQueue line with sampleRate:44100.0")
        XCTAssertEqual(stat?.sampleRate, 44100)
        XCTAssertEqual(stat?.priority, 3)
        XCTAssertEqual(stat?.processName, "Safari")
    }

    func testFirefoxSampleRateParses() {
        let line = "2026-07-04 09:00:00.000 Firefox[1234:5678] [fpfs_ReportAudioPlaybackThroughFigLog] [SampleRate 96000]"
        let stat = parser.parse(line: line, currentTrackName: nil)
        XCTAssertNotNil(stat)
        XCTAssertEqual(stat?.sampleRate, 96000)
        XCTAssertEqual(stat?.processName, "Firefox")
    }

    func testArcSampleRateParses() {
        let line = "2026-07-04 09:00:00.000 Arc[1234:5678] [fpfs_ReportAudioPlaybackThroughFigLog] [SampleRate 44100]"
        let stat = parser.parse(line: line, currentTrackName: nil)
        XCTAssertNotNil(stat)
        XCTAssertEqual(stat?.sampleRate, 44100)
        XCTAssertEqual(stat?.processName, "Arc")
    }

    // MARK: - Negative cases: no rate or out-of-range rate

    func testBrowserParserIgnoresUnknownRateLines() {
        // Browser audio line WITHOUT a sample rate.
        let line = "2026-07-04 09:00:00.000 Chrome[1234:5678] some audio buffer status update without rate"
        let stat = parser.parse(line: line, currentTrackName: nil)
        XCTAssertNil(stat, "Lines without a parseable sample rate must return nil")
    }

    func testBrowserParserIgnoresOutOfRangeRate() {
        // Rate outside the supported 8000...384000 window.
        let line = "2026-07-04 09:00:00.000 Chrome[1234:5678] [fpfs_ReportAudioPlaybackThroughFigLog] [SampleRate 100]"
        let stat = parser.parse(line: line, currentTrackName: nil)
        XCTAssertNil(stat, "Out-of-range sample rate (100 Hz) must be ignored")
    }

    // MARK: - Negative cases: non-browser process

    func testBrowserParserIgnoresNonBrowserProcesses() {
        // Music (Apple Music) line with a sample rate — must NOT be picked up by
        // the browser parser. The generic CoreMediaParser handles Music.
        let line = "2026-07-04 09:00:00.000 Music[1234:5678] [fpfs_ReportAudioPlaybackThroughFigLog] [SampleRate 48000]"
        let stat = parser.parse(line: line, currentTrackName: nil)
        XCTAssertNil(stat, "Non-browser processes must not be handled by BrowserCoreMediaParser")
    }

    func testBrowserParserIgnoresIINA() {
        let line = "2026-07-04 09:00:00.000 IINA[1234:5678] [fpfs_ReportAudioPlaybackThroughFigLog] [SampleRate 96000]"
        let stat = parser.parse(line: line, currentTrackName: nil)
        XCTAssertNil(stat, "IINA is not a browser and must not be handled by BrowserCoreMediaParser")
    }

    // MARK: - Helper functions

    func testIsBrowserProcessRecognizesKnownBrowsers() {
        XCTAssertTrue(isBrowserProcess("Safari"))
        XCTAssertTrue(isBrowserProcess("Chrome"))
        XCTAssertTrue(isBrowserProcess("Google Chrome"))
        XCTAssertTrue(isBrowserProcess("Brave Browser"))
        XCTAssertTrue(isBrowserProcess("Microsoft Edge"))
        XCTAssertTrue(isBrowserProcess("Arc"))
        XCTAssertTrue(isBrowserProcess("Firefox"))
        // Case-insensitive
        XCTAssertTrue(isBrowserProcess("safari"))
        XCTAssertTrue(isBrowserProcess("FIREFOX"))
    }

    func testIsBrowserProcessRejectsNonBrowsers() {
        XCTAssertFalse(isBrowserProcess("Music"))
        XCTAssertFalse(isBrowserProcess("IINA"))
        XCTAssertFalse(isBrowserProcess("Xcode"))
        XCTAssertFalse(isBrowserProcess(nil))
        XCTAssertFalse(isBrowserProcess(""))
    }

    func testExtractProcessNameFromLogLine() {
        let line = "2026-07-04 09:00:00.000 Chrome[1234:5678] some message"
        XCTAssertEqual(extractProcessName(from: line), "Chrome")
    }

    func testExtractProcessNameReturnsNilForMalformedLine() {
        let line = "no brackets here"
        // When there's no `[`, the whole preamble is used; last word is "here".
        // The function returns the last whitespace-separated token before `[`.
        // If there's no `[` at all, `line.range(of: "[")` is nil and it returns nil.
        // But wait — looking at the implementation: it only extracts if `[` is found.
        XCTAssertNil(extractProcessName(from: "no brackets here"),
                     "Without a `[` delimiter the process name cannot be extracted")
    }
}
