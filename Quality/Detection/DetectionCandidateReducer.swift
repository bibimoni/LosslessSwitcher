//
//  DetectionCandidateReducer.swift
//  Quality
//
//  Filters provider candidates before they reach latestStats. Rejects stale
//  candidates and repeated same-rate lower-confidence candidates so that
//  continuous playback does not trigger flashing or redundant switches.
//

import Foundation

struct DetectionCandidateReducer {
    private(set) var lastAccepted: DetectionCandidate?

    mutating func shouldAccept(_ candidate: DetectionCandidate, now: Date = Date()) -> Bool {
        // Reject already-expired candidates outright.
        guard candidate.expiresAt >= now else { return false }

        // If we have no live accepted candidate, accept this one.
        guard let current = lastAccepted, current.expiresAt >= now else {
            lastAccepted = candidate
            return true
        }

        let newStats = candidate.stats
        let oldStats = current.stats
        let isNewer = newStats.date >= oldStats.date
        let isHigherConfidence = candidate.confidence > current.confidence
        let isDifferentRate = abs(newStats.sampleRate - oldStats.sampleRate) >= 100

        // Accept when the new candidate is strictly more confident, OR when it is
        // both newer and represents a materially different sample rate. Same-rate
        // lower-or-equal-confidence duplicates are suppressed to avoid flashing.
        let accept = isHigherConfidence || (isNewer && isDifferentRate)
        if accept { lastAccepted = candidate }
        return accept
    }

    mutating func reset() {
        lastAccepted = nil
    }
}
