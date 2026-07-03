//
//  AudioSampleRateProvider.swift
//  Quality
//
//  Provider-based sample-rate detection. Providers publish DetectionCandidate
//  values that the LogStreamer reducer filters before they reach latestStats.
//

import Combine
import Foundation

/// Kind of source that produced a detection candidate. Mirrors the priority table
/// in the implementation plan (IINA local file = 7, CoreAudio log = 5, browser log = 3, etc.).
enum DetectionSourceKind: String {
    case coreAudioLog
    case coreMediaLog
    case iinaLocalFile
    case browserLog
}

/// A candidate sample-rate observation emitted by a provider.
struct DetectionCandidate {
    let stats: CMPlayerStats
    let sourceKind: DetectionSourceKind
    let confidence: Int
    let expiresAt: Date
    let diagnostic: String
}

/// Protocol for sources that can publish sample-rate candidates independently of the
/// `/usr/bin/log stream` pipeline. Providers are registered with LogStreamer and
/// started/stopped alongside the log process.
protocol AudioSampleRateProvider: AnyObject {
    var identifier: String { get }
    var candidatePublisher: AnyPublisher<DetectionCandidate, Never> { get }
    func start()
    func stop()
}
