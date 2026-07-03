//
//  LogParser.swift
//  Quality
//
//  Created by FantasticSkyBaby on 2026/03/13.
//

import Foundation
import OSLog

protocol LogParser {
    var identifier: String { get }
    func parse(line: String, currentTrackName: String?) -> CMPlayerStats?
}

struct CoreAudioParser: LogParser {
    let identifier = "CoreAudio"
    
    // 更加宽松的正则匹配
    private static let sampleRateRegex = try? NSRegularExpression(pattern: #"ch,\s*([0-9]+)\s*Hz"#, options: [])
    private static let bitDepthRegex = try? NSRegularExpression(pattern: #"from\s*(\d+)-bit\s*source"#, options: [])
    
    func parse(line: String, currentTrackName: String?) -> CMPlayerStats? {
        guard line.contains("ACAppleLosslessDecoder.cpp") && line.contains("Input format:") else { return nil }
        
        var sampleRate: Double?
        var bitDepth: Int?

        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        
        if let match = CoreAudioParser.sampleRateRegex?.firstMatch(in: line, options: [], range: range),
           let rateRange = Range(match.range(at: 1), in: line) {
            sampleRate = Double(line[rateRange])
        }
        
        if let match = CoreAudioParser.bitDepthRegex?.firstMatch(in: line, options: [], range: range),
           let depthRange = Range(match.range(at: 1), in: line) {
            bitDepth = Int(line[depthRange])
        }
        
        if let sr = sampleRate, let bd = bitDepth {
            var stat = CMPlayerStats(sampleRate: sr, bitDepth: bd, date: Date(), priority: 5)
            stat.processName = extractProcessName(from: line)
            if isMusicProcess(stat.processName) {
                stat.trackName = currentTrackName
            }
            return stat
        }
        return nil
    }
}

struct CoreMediaParser: LogParser {
    let identifier = "CoreMedia"
    
    private static let fpfsRateRegex = try? NSRegularExpression(pattern: #"\[SampleRate\s*([0-9]+)\]"#, options: [])
    private static let fpfsDepthRegex = try? NSRegularExpression(pattern: #"\[BitDepth\s*(\d+)\]"#, options: [])
    private static let audioQueueRateRegex = try? NSRegularExpression(pattern: #"sampleRate:\s*([0-9.]+)"#, options: [])
    
    func parse(line: String, currentTrackName: String?) -> CMPlayerStats? {
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        
        if line.contains("fpfs_ReportAudioPlaybackThroughFigLog") {
            var sampleRate: Double?
            var bitDepth: Int?

            if let match = CoreMediaParser.fpfsRateRegex?.firstMatch(in: line, options: [], range: range),
               let rateRange = Range(match.range(at: 1), in: line) {
                sampleRate = Double(line[rateRange])
            }

            if let match = CoreMediaParser.fpfsDepthRegex?.firstMatch(in: line, options: [], range: range),
               let depthRange = Range(match.range(at: 1), in: line) {
                bitDepth = Int(line[depthRange])
            }

            if let sr = sampleRate {
                var stat = CMPlayerStats(sampleRate: sr, bitDepth: bitDepth ?? 24, date: Date(), priority: 2)
                stat.processName = extractProcessName(from: line)
                if isMusicProcess(stat.processName) {
                    stat.trackName = currentTrackName
                }
                return stat
            }
        }
        
        if line.contains("Creating AudioQueue") {
            if let match = CoreMediaParser.audioQueueRateRegex?.firstMatch(in: line, options: [], range: range),
               let rateRange = Range(match.range(at: 1), in: line) {
                if let sr = Double(line[rateRange]) {
                    var stat = CMPlayerStats(sampleRate: sr, bitDepth: 24, date: Date(), priority: 2)
                    stat.processName = extractProcessName(from: line)
                    if isMusicProcess(stat.processName) {
                        stat.trackName = currentTrackName
                    }
                    return stat
                }
            }
        }
        
        return nil
    }
}

/// Browser process names whose CoreMedia/CoreAudio log lines should be treated
/// as browser playback candidates. Matched case-insensitively by `isBrowserProcess`.
let browserProcessNames: [String] = [
    "Safari",
    "Google Chrome",
    "Chrome",
    "Brave Browser",
    "Brave",
    "Microsoft Edge",
    "Edge",
    "Arc",
    "Firefox"
]

/// Extracts the process name from the preamble of a `/usr/bin/log` compact line.
/// Made internal (rather than private) so parsers and tests can share the same
/// extraction logic.
func extractProcessName(from line: String) -> String? {
    if let range = line.range(of: "[") {
        let preamble = line[..<range.lowerBound]
        if let lastWord = preamble.components(separatedBy: .whitespaces).last {
            return lastWord
        }
    }
    return nil
}

/// Returns true when the process name is Apple Music or iTunes.
func isMusicProcess(_ name: String?) -> Bool {
    guard let name = name?.lowercased() else { return false }
    return name == "music" || name == "itunes"
}

/// Returns true when the process name matches a known browser. Case-insensitive.
func isBrowserProcess(_ name: String?) -> Bool {
    guard let name = name?.lowercased() else { return false }
    return browserProcessNames.contains { $0.lowercased() == name }
}

/// Parser for CoreMedia/CoreAudio sample-rate log lines emitted by browser
/// processes (Safari, Chrome, Brave, Edge, Arc, Firefox). Emits a candidate
/// only when the line contains a parseable sample rate within the supported
/// range. Lines that mention browser audio but expose no rate return nil so
/// the generic CoreMediaParser can still handle them (or ignore them).
struct BrowserCoreMediaParser: LogParser {
    let identifier = "BrowserCoreMedia"

    static let supportedSampleRateRange: ClosedRange<Double> = 8000...384000

    private static let fpfsRateRegex = try? NSRegularExpression(pattern: #"\[SampleRate\s*([0-9]+)\]"#, options: [])
    private static let audioQueueRateRegex = try? NSRegularExpression(pattern: #"sampleRate:\s*([0-9.]+)"#, options: [])

    func parse(line: String, currentTrackName: String?) -> CMPlayerStats? {
        let processName = extractProcessName(from: line)
        guard isBrowserProcess(processName) else { return nil }

        let range = NSRange(line.startIndex..<line.endIndex, in: line)

        // Reuse the same patterns the generic CoreMediaParser uses, but only for
        // browser process names. Priority 3 sits above generic CoreMedia (priority 2)
        // but below CoreAudio Apple Lossless (priority 5).
        if let match = BrowserCoreMediaParser.fpfsRateRegex?.firstMatch(in: line, options: [], range: range),
           let rateRange = Range(match.range(at: 1), in: line) {
            let raw = line[rateRange]
            if let sr = Double(raw), Self.supportedSampleRateRange.contains(sr) {
                var stat = CMPlayerStats(sampleRate: sr, bitDepth: 24, date: Date(), priority: 3)
                stat.processName = processName
                stat.trackName = currentTrackName
                return stat
            }
            return nil
        }

        if let match = BrowserCoreMediaParser.audioQueueRateRegex?.firstMatch(in: line, options: [], range: range),
           let rateRange = Range(match.range(at: 1), in: line) {
            let raw = line[rateRange]
            if let sr = Double(raw), Self.supportedSampleRateRange.contains(sr) {
                var stat = CMPlayerStats(sampleRate: sr, bitDepth: 24, date: Date(), priority: 3)
                stat.processName = processName
                stat.trackName = currentTrackName
                return stat
            }
            return nil
        }

        // Browser audio line without a parseable sample rate — return nil so the
        // generic CoreMediaParser does not pick it up either (it has the same
        // patterns and would otherwise double-handle).
        return nil
    }
}
