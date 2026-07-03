# Provider-Based IINA and Browser Detection Implementation Plan

> **For agentic executors:** Use `subagent-driven-development` or `executing-plans` to implement this plan task-by-task.

**Goal:** Add non-invasive provider-based sample-rate detection for IINA local media playback and YouTube Music/browser playback without forcing IINA or browser audio output settings.

**Approach:** Preserve the current CoreAudio/CoreMedia log stream and wrap detection behind provider boundaries. Add an IINA local-file provider that discovers the currently opened media file from the IINA process and reads the file's audio metadata directly, plus browser log parsers that switch only when CoreMedia/CoreAudio logs contain a credible sample rate. Merge provider outputs into the existing `CMPlayerStats` pipeline with explicit priority, confidence, TTL, and stale-data safeguards.

**Tech Stack:** Swift 6.2.3, SwiftUI, Combine, XCTest, Xcode 26.2, `SimplyCoreAudio`, `Sweep`, `/usr/bin/log`, `/usr/sbin/lsof`, AudioToolbox/AVFoundation for media metadata, `gh` CLI for fork/PR operations.

## Current Repository State

**Fork:** `https://github.com/bibimoni/LosslessSwitcher`

**Local clone:** `/Users/distiled/Dev/exen-mcp/LosslessSwitcher`

**Upstream:** `https://github.com/FantasticSkyBaby/LosslessSwitcher`

**Relevant existing files:**
- `Quality/LogStreamer.swift` — launches `/usr/bin/log stream`, parses lines, publishes `latestStats`.
- `Quality/LogParser.swift` — contains `CoreAudioParser` and `CoreMediaParser`.
- `Quality/CMPlayerStuff.swift` — defines `CMPlayerStats` and legacy log parsing helpers.
- `Quality/OutputDevices.swift` — subscribes to `LogStreamer.shared.$latestStats` and applies sample-rate switches.
- `Quality/SampleRatePolicy.swift` — prevents stale/prebuffer/downgrade mis-switches.
- `LosslessSwitcherTests/OutputDevicesPrebufferTests.swift` — existing XCTest suite.

## Required Behavior

1. Apple Music behavior remains unchanged.
2. IINA local media playback does not require IINA `audio-exclusive` or `audio-device` mpv options.
3. IINA local FLAC/WAV/AIFF/M4A files can be detected by reading source-file audio metadata.
4. Browser/YouTube Music switches only when CoreMedia/CoreAudio logs expose a clear browser sample rate.
5. Unknown browser rates do not trigger a switch.
6. Stale provider data expires and cannot repeatedly flash/switch the output device.
7. Existing selected-output-device behavior remains unchanged: LosslessSwitcher switches its selected/default output device, not the playback application's device routing.

## Detection Priority Rules

| Priority | Source | Applies When | Action |
|---:|---|---|---|
| 7 | IINA local file metadata | IINA process has an open supported local media file and file metadata contains sample rate | Use sample rate; bit depth if available, else current/default bit-depth behavior |
| 5 | CoreAudio Apple Lossless decoder logs | Existing `ACAppleLosslessDecoder.cpp Input format` lines | Preserve current behavior |
| 3 | Browser/CoreMedia logs | Process name is Safari/Chrome/Brave/Edge/Arc/Firefox and line contains `SampleRate` or `sampleRate` | Use only if rate is in supported range and line is fresh |
| 2 | Existing CoreMedia AudioQueue logs | Existing `fpfs_ReportAudioPlaybackThroughFigLog` / `Creating AudioQueue` lines | Preserve behavior but tag source |
| 0 | Unknown/ambiguous | Any source without a parseable rate | Ignore and log debug note only |

## Implementation Tasks

### Task 1: Create Working Branch and Verify Fork Remotes

**Inputs:** local clone at `/Users/distiled/Dev/exen-mcp/LosslessSwitcher`
**Outputs:** branch `feature/provider-detection-iina-browser`
**Tools:** `git`, `gh`

- [ ] **Step: Verify active GitHub account and fork remote**

```bash
gh auth status
gh repo view bibimoni/LosslessSwitcher --json name,owner,url,defaultBranchRef
git remote -v
```

Expected:
- `bibimoni` is active.
- `origin` points to `https://github.com/bibimoni/LosslessSwitcher.git`.
- `upstream` points to `https://github.com/FantasticSkyBaby/LosslessSwitcher.git`.

- [ ] **Step: Create implementation branch**

```bash
git switch -c feature/provider-detection-iina-browser
```

Expected: `git branch --show-current` prints `feature/provider-detection-iina-browser`.

### Task 2: Repair/Verify Local Xcode Build Frontier

**Inputs:** `Quality.xcodeproj`
**Outputs:** confirmed build/test command availability or documented toolchain blocker
**Tools:** `xcodebuild`, `xcode-select`, `swift`

- [ ] **Step: Verify toolchain versions**

```bash
xcode-select -p
xcodebuild -version
swift --version
```

Expected:
- Xcode path: `/Applications/Xcode.app/Contents/Developer`
- Xcode reports a version.
- Swift reports an Apple Swift version.

- [ ] **Step: Verify project listing**

```bash
xcodebuild -list -project Quality.xcodeproj
```

Expected success output includes scheme `LosslessSwitcher`. If it fails with the local `IDESimulatorFoundation` plug-in error, run the repair step immediately.

- [ ] **Step: Repair Xcode first-launch content if required**

```bash
sudo xcodebuild -runFirstLaunch
xcodebuild -list -project Quality.xcodeproj
```

Expected: second command lists project targets/schemes. If it still fails, stop implementation and record the exact Xcode error in `.opencode/integration-status.md`; code changes can continue, but final build/test cannot be claimed until this gate passes.

### Task 3: Add Provider Model Types

**Inputs:** `Quality/CMPlayerStuff.swift`, `Quality/LogStreamer.swift`
**Outputs:** provider protocol and metadata structs compiled into app target
**Tools:** Swift, Xcode project file edits

- [ ] **Step: Add `Quality/Detection/AudioSampleRateProvider.swift`**

Create:

```swift
import Foundation
import Combine

enum DetectionSourceKind: String {
    case coreAudioLog
    case coreMediaLog
    case iinaLocalFile
    case browserLog
}

struct DetectionCandidate {
    let stats: CMPlayerStats
    let sourceKind: DetectionSourceKind
    let confidence: Int
    let expiresAt: Date
    let diagnostic: String
}

protocol AudioSampleRateProvider: AnyObject {
    var identifier: String { get }
    var candidatePublisher: AnyPublisher<DetectionCandidate, Never> { get }
    func start()
    func stop()
}
```

Expected: file exists and has no references to UI or hardware switching.

- [ ] **Step: Add file to Xcode target**

Use Xcode or edit `Quality.xcodeproj/project.pbxproj` to include `AudioSampleRateProvider.swift` in the `LosslessSwitcher` target.

Verify:

```bash
grep -n "AudioSampleRateProvider.swift" Quality.xcodeproj/project.pbxproj
```

Expected: at least one `PBXFileReference` and one `PBXSourcesBuildPhase` entry.

### Task 4: Refactor `LogStreamer` into Provider Aggregator Without Changing Existing Behavior

**Inputs:** `Quality/LogStreamer.swift`
**Outputs:** `LogStreamer` can accept external provider candidates and still parses existing log lines
**Tools:** Swift, Combine

- [ ] **Step: Add candidate reducer**

Add `Quality/Detection/DetectionCandidateReducer.swift`:

```swift
struct DetectionCandidateReducer {
    private(set) var lastAccepted: DetectionCandidate?

    mutating func shouldAccept(_ candidate: DetectionCandidate, now: Date = Date()) -> Bool {
        guard candidate.expiresAt >= now else { return false }
        guard let current = lastAccepted, current.expiresAt >= now else {
            lastAccepted = candidate
            return true
        }
        let newStats = candidate.stats
        let oldStats = current.stats
        let isNewer = newStats.date >= oldStats.date
        let isHigherConfidence = candidate.confidence > current.confidence
        let isDifferentRate = abs(newStats.sampleRate - oldStats.sampleRate) >= 100
        let accept = isHigherConfidence || (isNewer && isDifferentRate)
        if accept { lastAccepted = candidate }
        return accept
    }
}
```

Expected: stale candidates and repeated same-rate lower-confidence candidates are rejected before `latestStats` changes.

- [ ] **Step: Add provider storage to `LogStreamer`**

Modify `LogStreamer`:

```swift
private var providers: [AudioSampleRateProvider] = []
private var providerCancellables: [AnyCancellable] = []
private var candidateReducer = DetectionCandidateReducer()
```

Add:

```swift
func register(provider: AudioSampleRateProvider) {
    providers.append(provider)
    let cancellable = provider.candidatePublisher.sink { [weak self] candidate in
        self?.appendCandidate(candidate)
    }
    providerCancellables.append(cancellable)
}

func appendCandidate(_ candidate: DetectionCandidate) {
    guard candidateReducer.shouldAccept(candidate) else { return }
    appendDebugStat(candidate.stats)
}
```

Expected: existing `appendDebugStat(_:)` remains the single route to `latestStats`, and candidates pass through `DetectionCandidateReducer` first.

- [ ] **Step: Start/stop providers with log stream**

At the end of `start()` after successful process start, call `providers.forEach { $0.start() }`.
In `stop()`, call `providers.forEach { $0.stop() }` before clearing state.

Verify by build once Task 2 passes.

### Task 5: Add Media Metadata Reader for Local Files

**Inputs:** local media file URL
**Outputs:** source sample rate and bit depth candidate
**Tools:** AudioToolbox or AVFoundation, XCTest fixtures

- [ ] **Step: Add `Quality/Detection/AudioMetadataReader.swift`**

Implement:

```swift
struct AudioMetadata {
    let sampleRate: Double
    let bitDepth: Int?
    let codecDescription: String
}

enum AudioMetadataReader {
    static func read(url: URL) -> AudioMetadata?
}
```

Implementation rules:
- Use `AudioFileOpenURL` and `AudioFileGetProperty(kAudioFilePropertyDataFormat)` first.
- Return `mSampleRate` when it is between `8000...384000`.
- Return `mBitsPerChannel` only when greater than `0`.
- Close `AudioFileID` after reading.
- Return `nil` for directories, missing files, and unsupported files.

- [ ] **Step: Add metadata reader tests**

Add `LosslessSwitcherTests/AudioMetadataReaderTests.swift` with generated temporary WAV fixtures:

```swift
func testReadsSampleRateFromGeneratedWavFixture()
func testReturnsNilForUnsupportedTextFile()
```

Generate WAV fixture in test using `AVAudioFile` or write a short PCM WAV header. Expected: 44_100 Hz fixture returns `44100` within `0.001` tolerance.

### Task 6: Add IINA Open-File Provider

**Inputs:** running app `com.colliderli.iina`; open media file paths from `lsof`
**Outputs:** `DetectionCandidate` with `sourceKind = .iinaLocalFile`, priority/confidence 7
**Tools:** `NSWorkspace`, `/usr/sbin/lsof`, `AudioMetadataReader`, Combine timer

- [ ] **Step: Add `Quality/Detection/IINAOpenFileProvider.swift`**

Implement provider:
- Find running IINA apps by bundle ID `com.colliderli.iina`.
- For each PID, run `/usr/sbin/lsof -Fn -p <pid>` no more than once every 2 seconds.
- Parse lines beginning with `n` into file paths.
- Keep paths with extensions: `flac`, `wav`, `aif`, `aiff`, `m4a`, `mp3`, `ogg`, `opus`, `mp4`, `mkv`, `mov`.
- Exclude paths under `/Applications/IINA.app/`, `~/Library/Application Support/com.colliderli.iina/`, and subtitle extensions.
- Read metadata from the first stable candidate path that returns a sample rate.
- Emit `CMPlayerStats(sampleRate: metadata.sampleRate, bitDepth: metadata.bitDepth ?? 24, date: Date(), priority: 7)` with `processName = "IINA"`, `trackName = url.lastPathComponent`.
- Set `expiresAt = Date().addingTimeInterval(4)`.

- [ ] **Step: Add parser seam for tests**

Extract lsof parsing into a pure helper:

```swift
struct LsofMediaPathParser {
    static func mediaPaths(from output: String, homeDirectory: URL) -> [URL]
}
```

Expected: helper has no process execution side effects.

- [ ] **Step: Add IINA provider tests**

Add `LosslessSwitcherTests/IINAOpenFileProviderTests.swift`:

```swift
func testLsofParserKeepsFlacAndDropsAppResources()
func testLsofParserKeepsMostRelevantMediaExtensions()
func testProviderCandidateUsesMetadataReaderResult()
```

Expected: tests do not require IINA to be installed or running; they use fixture lsof output strings.

### Task 7: Add Browser Log Parser Provider Behavior

**Inputs:** CoreMedia/CoreAudio log lines from browser processes
**Outputs:** browser stats only for credible sample-rate lines
**Tools:** Swift regex, existing `LogParser`

- [ ] **Step: Extend `LogParser.swift` with source helpers**

Change private helpers to internal functions so tests can call them:

```swift
func extractProcessName(from line: String) -> String?
func isMusicProcess(_ name: String?) -> Bool
func isBrowserProcess(_ name: String?) -> Bool
```

Browser process names:
`Safari`, `Google Chrome`, `Chrome`, `Brave Browser`, `Brave`, `Microsoft Edge`, `Edge`, `Arc`, `Firefox`.

- [ ] **Step: Add `BrowserCoreMediaParser`**

Implement parser in `LogParser.swift`:

```swift
struct BrowserCoreMediaParser: LogParser { ... }
```

Rules:
- Parse only if `isBrowserProcess(extractProcessName(from: line))` is true.
- Reuse patterns `\[SampleRate\s*([0-9]+)\]` and `sampleRate:\s*([0-9.]+)`.
- Accept rates from `8000...384000`.
- Emit `CMPlayerStats(sampleRate: sr, bitDepth: 24, date: Date(), priority: 3)` with `processName` set to browser name.
- Return `nil` for lines that mention browser audio but do not include a parseable sample rate.

- [ ] **Step: Register browser parser before generic CoreMedia parser**

Update `LogStreamer.parsers`:

```swift
private var parsers: [LogParser] = [CoreAudioParser(), BrowserCoreMediaParser(), CoreMediaParser()]
```

Expected: existing Apple Music/CoreAudio behavior remains first and unchanged; browser-specific CoreMedia lines are handled before generic `CoreMediaParser` can consume them.

- [ ] **Step: Add browser parser tests**

Add `LosslessSwitcherTests/BrowserLogParserTests.swift`:

```swift
func testBrowserCoreMediaSampleRateParses()
func testBrowserParserIgnoresUnknownRateLines()
func testBrowserParserIgnoresNonBrowserProcesses()
```

Expected: browser parser only emits stats from browser process names.

### Task 8: Register Providers During App Startup

**Inputs:** `OutputDevices.init()` or app bootstrap path
**Outputs:** IINA provider registered once
**Tools:** Swift

- [ ] **Step: Register IINA provider before `LogStreamer.shared.start()`**

In `OutputDevices.init()`, before `LogStreamer.shared.start()`:

```swift
LogStreamer.shared.register(provider: IINAOpenFileProvider())
```

Guard against duplicate registration by adding `registeredProviderIDs` to `LogStreamer`:

```swift
private var registeredProviderIDs = Set<String>()
```

Expected: repeated `OutputDevices` construction in tests does not register duplicate providers.

- [ ] **Step: Disable provider side effects in existing tests**

Existing test subclasses call `LogStreamer.shared.stop()` in `setUp`. Add a debug-only reset method to clear providers if needed:

```swift
#if DEBUG
func resetProviderStateForTests() { ... }
#endif
```

Expected: existing tests remain deterministic.

### Task 9: Stabilize Candidate Expiry and Flash Behavior

**Inputs:** `LogStreamer`, `OutputDevices`, `SampleRatePolicy`
**Outputs:** stale provider candidates ignored; UI does not flash repeatedly for same rate
**Tools:** Swift, XCTest

- [ ] **Step: Prevent repeated same-file candidate churn**

In `IINAOpenFileProvider`, cache last emitted tuple `(path, sampleRate, bitDepth)` and emit again only when tuple changes or after 10 seconds.

Expected: continuous IINA playback does not publish the same stat every 2 seconds.

- [ ] **Step: Add same-rate no-flash regression test**

Add test to existing suite or new provider suite:

```swift
func testRepeatedSameIINAStatDoesNotTriggerRepeatedGeneration()
```

Expected: second identical provider candidate is suppressed before `LogStreamer.latestStats` changes.

### Task 10: Unit Test Full Parser and Provider Surface

**Inputs:** all new test files
**Outputs:** passing XCTest parser/provider suite
**Tools:** `xcodebuild test`

- [ ] **Step: Run focused XCTest suite**

```bash
xcodebuild test \
  -project Quality.xcodeproj \
  -scheme LosslessSwitcher \
  -destination 'platform=macOS' \
  -only-testing:LosslessSwitcherTests/AudioMetadataReaderTests \
  -only-testing:LosslessSwitcherTests/IINAOpenFileProviderTests \
  -only-testing:LosslessSwitcherTests/BrowserLogParserTests
```

Expected: exit 0; output contains `** TEST SUCCEEDED **`.

- [ ] **Step: Run existing regression tests**

```bash
xcodebuild test \
  -project Quality.xcodeproj \
  -scheme LosslessSwitcher \
  -destination 'platform=macOS'
```

Expected: exit 0; output contains `** TEST SUCCEEDED **`.

### Task 11: Build Debug and Release Apps

**Inputs:** app source and Xcode project
**Outputs:** built `.app` products in DerivedData
**Tools:** `xcodebuild`

- [ ] **Step: Clean build folder**

```bash
xcodebuild clean \
  -project Quality.xcodeproj \
  -scheme LosslessSwitcher \
  -configuration Debug
```

Expected: exit 0; output contains `** CLEAN SUCCEEDED **`.

- [ ] **Step: Build Debug**

```bash
xcodebuild build \
  -project Quality.xcodeproj \
  -scheme LosslessSwitcher \
  -configuration Debug \
  -destination 'platform=macOS'
```

Expected: exit 0; output contains `** BUILD SUCCEEDED **`.

- [ ] **Step: Build Release**

```bash
xcodebuild build \
  -project Quality.xcodeproj \
  -scheme LosslessSwitcher \
  -configuration Release \
  -destination 'platform=macOS'
```

Expected: exit 0; output contains `** BUILD SUCCEEDED **`.

### Task 12: Manual Local Deployment for E2E Testing

**Inputs:** Debug or Release app product
**Outputs:** installed local test copy of LosslessSwitcher
**Tools:** `xcodebuild`, Finder or `open`, macOS Activity Monitor if needed

- [ ] **Step: Locate built app**

```bash
APP_PATH=$(xcodebuild -showBuildSettings \
  -project Quality.xcodeproj \
  -scheme LosslessSwitcher \
  -configuration Debug \
  -destination 'platform=macOS' \
  | awk -F'= ' '/ TARGET_BUILD_DIR / {dir=$2} / WRAPPER_NAME / {name=$2} END {print dir "/" name}')
test -d "$APP_PATH" && printf '%s\n' "$APP_PATH"
```

Expected: prints a path ending in `LosslessSwitcher.app`.

- [ ] **Step: Stop currently installed app before E2E**

```bash
osascript -e 'tell application id "com.vincent-neo.LosslessSwitcher" to quit' || true
pgrep -fl LosslessSwitcher || true
```

Expected: no running `LosslessSwitcher` process after quit.

- [ ] **Step: Launch built test app**

```bash
open "$APP_PATH"
sleep 3
pgrep -fl LosslessSwitcher
```

Expected: one running `LosslessSwitcher` process from the build output path.

### Task 13: E2E Test IINA Local FLAC Without IINA Audio Config

**Inputs:** running test LosslessSwitcher, IINA with `userOptions = []`, local FLAC fixtures
**Outputs:** selected/default output sample rate switches to source file rate
**Tools:** IINA, `ffmpeg`, `system_profiler`, `log show`

- [ ] **Step: Verify IINA does not force audio config**

```bash
python3 - <<'PY'
import plistlib, os
p=os.path.expanduser('~/Library/Preferences/com.colliderli.iina.plist')
with open(p,'rb') as f:
    d=plistlib.load(f)
print(d.get('userOptions', []))
PY
```

Expected: printed list does not contain `audio-exclusive` or `audio-device`.

- [ ] **Step: Generate local FLAC fixtures**

```bash
mkdir -p /var/folders/8s/n16pgznx2q9cq6vn2b04fvq00000gn/T/opencode/lossless-e2e
ffmpeg -hide_banner -loglevel error -y -f lavfi -i anullsrc=r=44100:cl=stereo -t 12 -sample_fmt s16 /var/folders/8s/n16pgznx2q9cq6vn2b04fvq00000gn/T/opencode/lossless-e2e/e2e-44k.flac
ffmpeg -hide_banner -loglevel error -y -f lavfi -i anullsrc=r=96000:cl=stereo -t 12 -sample_fmt s16 /var/folders/8s/n16pgznx2q9cq6vn2b04fvq00000gn/T/opencode/lossless-e2e/e2e-96k.flac
ffprobe -v error -show_entries stream=sample_rate -of default=nw=1 /var/folders/8s/n16pgznx2q9cq6vn2b04fvq00000gn/T/opencode/lossless-e2e/e2e-44k.flac
ffprobe -v error -show_entries stream=sample_rate -of default=nw=1 /var/folders/8s/n16pgznx2q9cq6vn2b04fvq00000gn/T/opencode/lossless-e2e/e2e-96k.flac
```

Expected: prints `sample_rate=44100` and `sample_rate=96000`.

- [ ] **Step: Play 44.1 kHz file in IINA and verify output device rate**

```bash
open -a IINA /var/folders/8s/n16pgznx2q9cq6vn2b04fvq00000gn/T/opencode/lossless-e2e/e2e-44k.flac
sleep 6
system_profiler SPAudioDataType | grep -A8 -E 'RETRO NANO|Default Output Device|Current SampleRate'
```

Expected: the LosslessSwitcher-selected or macOS default output device reports `Current SampleRate: 44100` when that device supports 44.1 kHz.

- [ ] **Step: Play 96 kHz file in IINA and verify output device rate**

```bash
open -a IINA /var/folders/8s/n16pgznx2q9cq6vn2b04fvq00000gn/T/opencode/lossless-e2e/e2e-96k.flac
sleep 6
system_profiler SPAudioDataType | grep -A8 -E 'RETRO NANO|Default Output Device|Current SampleRate'
```

Expected: the same output device reports `Current SampleRate: 96000` when it supports 96 kHz.

- [ ] **Step: Verify debug logs identify IINA provider**

```bash
log show --last 2m --style compact --predicate 'process == "LosslessSwitcher" AND eventMessage CONTAINS[c] "IINA"'
```

Expected: log line includes IINA source path or diagnostic from `IINAOpenFileProvider` and the detected sample rate.

### Task 14: E2E Test YouTube Music / Browser Detection

**Inputs:** running test LosslessSwitcher, browser playback from YouTube Music
**Outputs:** browser detection switches only when a sample-rate log exists; otherwise no switch and debug notes are clear
**Tools:** Chrome/Safari/browser, `log stream`, `log show`, `system_profiler`

- [ ] **Step: Start log observation before browser playback**

```bash
log stream --style compact --predicate '(subsystem == "com.apple.coremedia" OR subsystem == "com.apple.coreaudio") AND (process CONTAINS "Chrome" OR process CONTAINS "Safari" OR process CONTAINS "Brave" OR process CONTAINS "Arc" OR eventMessage CONTAINS[c] "SampleRate" OR eventMessage CONTAINS[c] "sampleRate")'
```

Expected: command streams logs; keep it open during the browser playback check.

- [ ] **Step: Play YouTube Music in one browser**

Manual action: open `https://music.youtube.com`, play a track for at least 30 seconds.

Expected:
- If CoreMedia/CoreAudio emits browser sample-rate logs, LosslessSwitcher debug logs show browser detection and one switch to the detected rate.
- If no sample-rate logs appear, LosslessSwitcher does not switch and does not flash repeatedly.

- [ ] **Step: Verify no random switch when browser rate is unknown**

```bash
system_profiler SPAudioDataType | grep -A8 -E 'RETRO NANO|Default Output Device|Current SampleRate'
log show --last 2m --style compact --predicate 'process == "LosslessSwitcher" AND (eventMessage CONTAINS[c] "browser" OR eventMessage CONTAINS[c] "unknown" OR eventMessage CONTAINS[c] "Switch")'
```

Expected: no repeated switching loop. Any browser-related log must either include a sample rate or state that browser rate is unknown/ignored.

### Task 15: Regression E2E for Apple Music

**Inputs:** running test LosslessSwitcher, Apple Music playback with known local/lossless content
**Outputs:** Apple Music sample-rate switching remains unchanged
**Tools:** Apple Music, `system_profiler`, `log show`

- [ ] **Step: Play known Apple Music/local lossless content**

Manual action: play a track that previously switched correctly.

Verify:

```bash
sleep 8
system_profiler SPAudioDataType | grep -A8 -E 'RETRO NANO|Default Output Device|Current SampleRate'
log show --last 2m --style compact --predicate 'process == "LosslessSwitcher" AND eventMessage CONTAINS[c] "Switch"'
```

Expected: sample rate matches previous working behavior; no new downgrade loop or flashing loop.

### Task 16: Packaging / Deployment Candidate

**Inputs:** release build and successful E2E notes
**Outputs:** local release candidate `.app` and optional zip artifact
**Tools:** `xcodebuild`, `ditto`, `codesign`

- [ ] **Step: Build release artifact**

```bash
xcodebuild build \
  -project Quality.xcodeproj \
  -scheme LosslessSwitcher \
  -configuration Release \
  -destination 'platform=macOS'
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step: Locate release app and inspect signature**

```bash
APP_PATH=$(xcodebuild -showBuildSettings \
  -project Quality.xcodeproj \
  -scheme LosslessSwitcher \
  -configuration Release \
  -destination 'platform=macOS' \
  | awk -F'= ' '/ TARGET_BUILD_DIR / {dir=$2} / WRAPPER_NAME / {name=$2} END {print dir "/" name}')
codesign --display --verbose=2 "$APP_PATH"
```

Expected: `codesign` displays app signature metadata. If signing identity is ad-hoc/local, record that the artifact is for local testing only.

- [ ] **Step: Create local zip artifact**

```bash
ARTIFACT=/var/folders/8s/n16pgznx2q9cq6vn2b04fvq00000gn/T/opencode/LosslessSwitcher-provider-detection.zip
ditto -c -k --keepParent "$APP_PATH" "$ARTIFACT"
test -s "$ARTIFACT" && ls -lh "$ARTIFACT"
```

Expected: non-empty zip file exists.

### Task 17: Documentation Updates

**Inputs:** `README.md`
**Outputs:** documented provider behavior and limitations
**Tools:** Markdown

- [ ] **Step: Document IINA support**

Update `README.md` with:
- IINA local-file detection works for files that remain open and readable by the IINA process.
- No IINA `audio-exclusive` or fixed `audio-device` configuration is required.
- DRM/streamed/network-only content may not expose source sample rate.

- [ ] **Step: Document browser support**

Update `README.md` with:
- Browser/YouTube Music detection depends on CoreMedia/CoreAudio sample-rate logs.
- If the browser only exposes mixed/resampled system output or no rate, LosslessSwitcher will not switch.
- Unknown rates are ignored to prevent random switching.

Verify:

```bash
grep -n "IINA\|YouTube Music\|browser" README.md
```

Expected: all three topics are documented.

### Task 18: Final Verification Before PR

**Inputs:** completed implementation branch
**Outputs:** evidence bundle for PR
**Tools:** `git`, `xcodebuild`, `gh`

- [ ] **Step: Verify clean command results**

```bash
xcodebuild test -project Quality.xcodeproj -scheme LosslessSwitcher -destination 'platform=macOS'
xcodebuild build -project Quality.xcodeproj -scheme LosslessSwitcher -configuration Release -destination 'platform=macOS'
git status --short
```

Expected:
- Tests pass.
- Release build succeeds.
- `git status --short` shows only intended source/test/doc/plan changes.

- [ ] **Step: Secret scan diff manually before push**

```bash
git diff -- Quality LosslessSwitcherTests README.md docs/turingskills/plans/2026-07-04-provider-detection-iina-browser.md
```

Expected: no tokens, passwords, local private paths outside documented test temp paths, or personal credentials.

- [ ] **Step: Commit and push**

```bash
git add Quality LosslessSwitcherTests README.md docs/turingskills/plans/2026-07-04-provider-detection-iina-browser.md
git commit -m "feat: add provider-based audio detection"
git push -u origin feature/provider-detection-iina-browser
```

Expected: branch pushed to `bibimoni/LosslessSwitcher`.

- [ ] **Step: Create PR against fork or upstream as requested**

For a fork-only PR:

```bash
gh pr create --repo bibimoni/LosslessSwitcher --base main --head feature/provider-detection-iina-browser --title "Add provider-based IINA and browser detection" --body-file /var/folders/8s/n16pgznx2q9cq6vn2b04fvq00000gn/T/opencode/provider-detection-pr.md
```

For an upstream PR:

```bash
gh pr create --repo FantasticSkyBaby/LosslessSwitcher --base main --head bibimoni:feature/provider-detection-iina-browser --title "Add provider-based IINA and browser detection" --body-file /var/folders/8s/n16pgznx2q9cq6vn2b04fvq00000gn/T/opencode/provider-detection-pr.md
```

Expected: `gh` prints PR URL.

## PR Body Template

Create `/var/folders/8s/n16pgznx2q9cq6vn2b04fvq00000gn/T/opencode/provider-detection-pr.md` with:

```markdown
## Summary
- Adds provider-based sample-rate detection.
- Adds IINA local-file metadata detection without forcing IINA audio output options.
- Adds browser/CoreMedia sample-rate parsing with unknown-rate safeguards.

## Test Evidence
- xcodebuild test: PASS
- xcodebuild Release build: PASS
- IINA 44.1 kHz FLAC E2E: PASS
- IINA 96 kHz FLAC E2E: PASS
- Browser/YouTube Music E2E: PASS or UNKNOWN-RATE SAFEGUARD VERIFIED
- Apple Music regression E2E: PASS

## Notes
- Browser switching depends on OS/browser sample-rate logs being emitted.
- Unknown browser rates are ignored to avoid false switches.
```

## Completion Criteria

Implementation is finished only when all of the following are true:

1. Fork branch exists on `bibimoni/LosslessSwitcher`.
2. Provider model compiles.
3. IINA local file provider unit tests pass.
4. Browser log parser unit tests pass.
5. Existing Apple Music/prebuffer tests pass.
6. Debug build succeeds.
7. Release build succeeds.
8. IINA E2E switches between 44.1 kHz and 96 kHz using local files without IINA `audio-device` or `audio-exclusive` options.
9. Browser/YouTube Music E2E either switches on credible sample-rate logs or explicitly ignores unknown rate without random switching.
10. Apple Music regression E2E still passes.
11. README documents IINA/browser behavior and limitations.
12. PR is created or branch URL is reported, depending on final deployment target.
