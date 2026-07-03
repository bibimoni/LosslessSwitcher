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

    /// Like `mediaPaths(from:homeDirectory:)` but returns (URL, fdCount) tuples
    /// sorted by fd count descending. Used by the provider to pick the
    /// actively-playing file across multiple IINA instances.
    static func mediaPathsWithFdCounts(from output: String, homeDirectory: URL) -> [(URL, Int)] {
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
                fdToPath.append((fd: fd, path: expanded))
            }
        }

        // Count fds per path, keeping the highest fd for tiebreaking.
        var pathStats: [String: (count: Int, maxFd: Int)] = [:]
        for entry in fdToPath {
            let current = pathStats[entry.path] ?? (count: 0, maxFd: 0)
            pathStats[entry.path] = (count: current.count + 1, maxFd: max(current.maxFd, entry.fd))
        }

        let sorted = pathStats.sorted {
            if $0.value.count != $1.value.count {
                return $0.value.count > $1.value.count
            }
            return $0.value.maxFd > $1.value.maxFd
        }

        return sorted.map { (URL(fileURLWithPath: $0.key), $0.value.count) }
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

        var bestCandidate: (url: URL, metadata: AudioMetadata)?

        for pid in pids {
            if let last = lastLsofAt[pid], now.timeIntervalSince(last) < Self.lsofInterval {
                continue
            }
            lastLsofAt[pid] = now

            // PRIORITY 1: Query mpv IPC for the exact playing file path.
            // IINA can have multiple mpv instances (one per window), each with
            // its own IPC socket. We query `pause` and `path` on each socket
            // and pick the one that is NOT paused.
            if let playingPath = Self.queryMpvPlayingPath(pid: pid) {
                let url = URL(fileURLWithPath: playingPath)
                if let metadata = AudioMetadataReader.read(url: url) {
                    bestCandidate = (url, metadata)
                    continue
                }
            }

            // PRIORITY 2: Fall back to lsof fd-count heuristic when IPC fails.
            guard let output = Self.runLsof(pid: pid) else { continue }
            let home = FileManager.default.homeDirectoryForCurrentUser
            let mediaWithCounts = LsofMediaPathParser.mediaPathsWithFdCounts(from: output, homeDirectory: home)

            for (url, _) in mediaWithCounts {
                if let metadata = AudioMetadataReader.read(url: url) {
                    if bestCandidate == nil {
                        bestCandidate = (url, metadata)
                    }
                    break
                }
            }
        }

        guard let best = bestCandidate else { return }
        emitCandidate(url: best.url, metadata: best.metadata, now: now)
    }

    private func emitCandidate(url: URL, metadata: AudioMetadata, now: Date) {
        // When the playing file changes, clear the debug track history so old
        // songs from previous playback don't clutter the menu.
        if lastEmittedPath != nil && lastEmittedPath != url.path {
            DispatchQueue.main.async {
                LogStreamer.shared.recentTracks.removeAll()
            }
        }
        lastEmittedPath = url.path

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

    /// Checks if an IINA instance is actively playing (not paused) by querying
    /// its mpv IPC socket. Falls back to `true` if the socket can't be found
    /// or the query fails — this avoids suppressing detection when IPC is
    /// unavailable (e.g. IINA too old or IPC disabled).
    static func isIINAPlaying(pid: pid_t) -> Bool {
        guard let sockets = findMpvSockets(forPid: pid), !sockets.isEmpty else {
            return true
        }
        for socket in sockets {
            let response = queryMpvIPC(socketPath: socket, property: "pause")
            if let data = response.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let dataValue = json["data"] as? Bool {
                return !dataValue
            }
        }
        return true
    }

    /// Queries mpv IPC for the `path` property of the **actively playing**
    /// (non-paused) mpv instance. IINA can have multiple mpv instances (one per
    /// window), each with its own IPC socket. We query `pause` and `path` on
    /// each socket and return the path from the one that is NOT paused.
    /// Returns nil if no playing instance is found.
    static func queryMpvPlayingPath(pid: pid_t) -> String? {
        guard let sockets = findMpvSockets(forPid: pid), !sockets.isEmpty else {
            return nil
        }

        var fallbackPath: String?

        for socket in sockets {
            // Check if this instance is paused.
            let pauseResponse = queryMpvIPC(socketPath: socket, property: "pause")
            let isPaused = parseBoolProperty(from: pauseResponse, key: "data")

            // Get the path for this instance.
            let pathResponse = queryMpvIPC(socketPath: socket, property: "path")
            let path = parseStringProperty(from: pathResponse, key: "data")

            if isPaused == false, let path = path, !path.isEmpty {
                // This instance is actively playing — return its path immediately.
                return expandPath(path)
            }

            // Keep the first non-empty path as a fallback in case all
            // instances report as paused (e.g. during a brief transition).
            if fallbackPath == nil, let path = path, !path.isEmpty {
                fallbackPath = expandPath(path)
            }
        }

        return fallbackPath
    }

    private static func expandPath(_ path: String) -> String {
        if path.hasPrefix("~") {
            return FileManager.default.homeDirectoryForCurrentUser.path + String(path.dropFirst())
        }
        return path
    }

    private static func parseBoolProperty(from json: String, key: String) -> Bool? {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj[key] as? Bool
    }

    private static func parseStringProperty(from json: String, key: String) -> String? {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj[key] as? String
    }

    /// Finds mpv IPC socket paths for a given IINA PID by listing /tmp and
    /// checking which sockets are held open by that PID.
    private static func findMpvSockets(forPid pid: pid_t) -> [String]? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-U", "-F", "n", "-a", "-p", String(pid)]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else { return nil }

        // Parse lines starting with 'n' that contain "mpv-ipc-handle".
        return output.components(separatedBy: .newlines)
            .filter { $0.hasPrefix("n") && $0.contains("mpv-ipc-handle") }
            .map { String($0.dropFirst()) }
    }

    /// Sends a `get_property` command to an mpv IPC Unix socket and returns the response.
    private static func queryMpvIPC(socketPath: String, property: String) -> String {
        let request = "{\"command\":[\"get_property\",\"\(property)\"]}\n"
        guard let requestData = request.data(using: .utf8) else { return "" }

        let fd = Darwin.socket(Darwin.AF_UNIX, Darwin.SOCK_STREAM, 0)
        guard fd >= 0 else { return "" }
        defer { Darwin.close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(Darwin.AF_UNIX)
        socketPath.withCString { cPath in
            withUnsafeMutablePointer(to: &addr.sun_path) { pathPtr in
                pathPtr.withMemoryRebound(to: CChar.self, capacity: 104) { cCharPtr in
                    _ = Darwin.strncpy(cCharPtr, cPath, 103)
                }
            }
        }

        let connectResult = withUnsafePointer(to: &addr) { addrPtr in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connectResult == 0 else { return "" }

        // Set a 1-second timeout so we don't hang if the socket is stale.
        var timeout = timeval(tv_sec: 1, tv_usec: 0)
        Darwin.setsockopt(fd, Darwin.SOL_SOCKET, Darwin.SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        _ = requestData.withUnsafeBytes { buffer in
            Darwin.send(fd, buffer.baseAddress, buffer.count, 0)
        }

        var buffer = [UInt8](repeating: 0, count: 4096)
        let bytesRead = buffer.withUnsafeMutableBufferPointer { ptr in
            Darwin.recv(fd, ptr.baseAddress, ptr.count, 0)
        }
        if bytesRead > 0 {
            return String(bytes: buffer.prefix(bytesRead), encoding: .utf8) ?? ""
        }
        return ""
    }
}
