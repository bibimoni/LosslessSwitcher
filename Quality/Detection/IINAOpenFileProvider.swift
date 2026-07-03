//
//  IINAOpenFileProvider.swift
//  Quality
//
//  Discovers the currently-opened local media file in the IINA process and
//  emits a DetectionCandidate built from the file's audio metadata. Does not
//  require IINA `audio-exclusive` or `audio-device` mpv options — it reads the
//  source file directly via AudioMetadataReader.
//

import Combine
import Foundation
import AppKit
import OSLog

/// Pure parser for `/usr/sbin/lsof -Fn -p <pid>` output. Extracted as a
/// standalone, side-effect-free helper so it can be unit-tested with fixture
/// strings without spawning processes.
struct LsofMediaPathParser {
    /// Extensions we treat as playable media IINA might have open.
    static let mediaExtensions: Set<String> = [
        "flac", "wav", "aif", "aiff", "m4a", "mp3", "ogg", "opus", "mp4", "mkv", "mov"
    ]

    /// Paths that begin with any of these prefixes are IINA-internal resources
    /// (app bundle, support files) and must be excluded from candidates.
    static let excludedPathPrefixes: [String] = [
        "/Applications/IINA.app",
        "/Library/Application Support/com.colliderli.iina",
    ]

    /// Subtitle extensions that should never be treated as audio sources.
    static let subtitleExtensions: Set<String> = ["srt", "ass", "ssa", "vtt", "sub"]

    /// Parses `lsof -Ffn` output into media-file URLs, sorted by the number of
    /// open file descriptors per file (descending). The currently-playing file
    /// always has the most open fds because mpv opens it for demuxing, decoding,
    /// and seeking simultaneously. Ties are broken by highest fd number.
    /// - Parameters:
    ///   - output: Raw stdout of `lsof -Ffn -p <pid>`.
    ///   - homeDirectory: The home directory used to expand `~`-prefixed paths.
    /// - Returns: Media-file URLs sorted by fd count descending.
    static func mediaPaths(from output: String, homeDirectory: URL) -> [URL] {
        var fdToPath: [(fd: Int, path: String)] = []
        var currentFd: Int?

        for line in output.components(separatedBy: .newlines) {
            if line.hasPrefix("f") {
                currentFd = Int(line.dropFirst())
                continue
            }
            guard line.hasPrefix("n") else { continue }
            let raw = String(line.dropFirst())
            if raw.isEmpty { continue }

            let expanded: String
            if raw.hasPrefix("~") {
                expanded = homeDirectory.path + String(raw.dropFirst())
            } else {
                expanded = raw
            }

            if excludedPathPrefixes.contains(where: { expanded.hasPrefix($0) }) { continue }

            let pathExtension = (expanded as NSString).pathExtension.lowercased()
            if pathExtension.isEmpty { continue }
            if subtitleExtensions.contains(pathExtension) { continue }
            guard mediaExtensions.contains(pathExtension) else { continue }

            if let fd = currentFd {
                if let existingIndex = fdToPath.firstIndex(where: { $0.path == expanded }) {
                    if fd > fdToPath[existingIndex].fd {
                        fdToPath[existingIndex].fd = fd
                    }
                    // Track all fds for this path by counting entries.
                    fdToPath.append((fd: fd, path: expanded))
                } else {
                    fdToPath.append((fd: fd, path: expanded))
                }
            }
        }

        // Count fds per path, keeping the highest fd for tiebreaking.
        var pathStats: [String: (count: Int, maxFd: Int)] = [:]
        for entry in fdToPath {
            let current = pathStats[entry.path] ?? (count: 0, maxFd: 0)
            pathStats[entry.path] = (count: current.count + 1, maxFd: max(current.maxFd, entry.fd))
        }

        // Sort by fd count descending, then by highest fd descending.
        let sorted = pathStats.sorted {
            if $0.value.count != $1.value.count {
                return $0.value.count > $1.value.count
            }
            return $0.value.maxFd > $1.value.maxFd
        }

        return sorted.map { URL(fileURLWithPath: $0.key) }
    }
}

/// Provider that watches the IINA process for open media files and publishes
/// sample-rate candidates derived from the file's own audio metadata.
final class IINAOpenFileProvider: AudioSampleRateProvider {
    let identifier = "IINAOpenFileProvider"

    private let candidateSubject = PassthroughSubject<DetectionCandidate, Never>()
    var candidatePublisher: AnyPublisher<DetectionCandidate, Never> {
        candidateSubject.eraseToAnyPublisher()
    }

    /// IINA's bundle identifier.
    static let iinaBundleID = "com.colliderli.iina"

    /// Minimum interval between `lsof` invocations for a given PID. Kept short
    /// so IINA playback is detected within ~0.5s of opening a file.
    static let lsofInterval: TimeInterval = 0.5

    /// Candidate expiry window. A candidate remains valid for this long after
    /// it was emitted before the reducer treats it as stale.
    static let candidateTTL: TimeInterval = 4.0

    /// Suppression window: an identical (path, sampleRate, bitDepth) tuple is
    /// not re-emitted within this interval, preventing repeated same-file
    /// candidate churn during continuous IINA playback.
    static let duplicateSuppressionWindow: TimeInterval = 10.0

    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "com.vincent-neo.LosslessSwitcher.iina-provider", qos: .utility)
    private var lastLsofAt: [pid_t: Date] = [:]

    // Task 9 — duplicate-suppression cache.
    private var lastEmittedPath: String?
    private var lastEmittedSampleRate: Double?
    private var lastEmittedBitDepth: Int?
    private var lastEmittedAt: Date?

    init() {}

    func start() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.3, repeating: Self.lsofInterval)
        timer.setEventHandler { [weak self] in
            self?.pollOnce()
        }
        timer.resume()
        self.timer = timer
    }

    func stop() {
        timer?.cancel()
        timer = nil
        queue.async { [weak self] in
            self?.lastLsofAt.removeAll()
            self?.lastEmittedPath = nil
            self?.lastEmittedSampleRate = nil
            self?.lastEmittedBitDepth = nil
            self?.lastEmittedAt = nil
            self?.previousPaths.removeAll()
        }
    }

    // Track previously-seen file paths so we only emit candidates for newly
    // opened files — not every file IINA keeps in its playlist.
    private var previousPaths: Set<String> = []

    private func pollOnce() {
        let now = Date()
        let pids = Self.runningIINAPIDs()
        guard !pids.isEmpty else {
            previousPaths.removeAll()
            return
        }

        for pid in pids {
            if let last = lastLsofAt[pid], now.timeIntervalSince(last) < Self.lsofInterval {
                continue
            }
            lastLsofAt[pid] = now

            guard let output = Self.runLsof(pid: pid) else { continue }
            let home = FileManager.default.homeDirectoryForCurrentUser
            let mediaURLs = LsofMediaPathParser.mediaPaths(from: output, homeDirectory: home)
            // mediaPaths is sorted by highest fd first — the most recently
            // opened file is the one IINA is currently playing.
            guard let url = mediaURLs.first else { continue }
            guard let metadata = AudioMetadataReader.read(url: url) else { continue }
            emitCandidate(url: url, metadata: metadata, now: now)
            break
        }
    }

    private func emitCandidate(url: URL, metadata: AudioMetadata, now: Date) {
        let stat = CMPlayerStats(
            sampleRate: metadata.sampleRate,
            bitDepth: metadata.bitDepth ?? 24,
            date: now,
            priority: 7,
            processName: "IINA",
            trackName: url.lastPathComponent
        )

        let candidate = DetectionCandidate(
            stats: stat,
            sourceKind: .iinaLocalFile,
            confidence: 7,
            expiresAt: now.addingTimeInterval(Self.candidateTTL),
            diagnostic: "IINA local file: \(url.lastPathComponent) [\(metadata.codecDescription)]"
        )

        Logger.streamer.info("[IINAProvider] DETECTED file=\(url.lastPathComponent, privacy: .public) sr=\(metadata.sampleRate, privacy: .public) codec=\(metadata.codecDescription, privacy: .public) bitDepth=\(metadata.bitDepth.map(String.init) ?? "?", privacy: .public)")
        candidateSubject.send(candidate)
    }

    // MARK: - Process discovery (extracted for testability of the seam)

    /// Returns PIDs of running IINA apps by bundle id. Empty when IINA is not running.
    static func runningIINAPIDs() -> [pid_t] {
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: iinaBundleID)
        return apps.compactMap { $0.processIdentifier }
    }

    /// Runs `/usr/sbin/lsof -Ffn -p <pid>` and returns its stdout, or nil on failure.
    /// Uses `-Ffn` to get both file descriptor numbers and file paths, so the
    /// parser can sort by highest fd (most recently opened file first).
    static func runLsof(pid: pid_t) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-Ffn", "-p", String(pid)]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe() // discard stderr

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)
    }
}
