//
//  AudioMetadataReader.swift
//  Quality
//
//  Reads source sample rate (and bit depth when available) directly from a
//  local media file. Used by the IINA local-file provider to detect sample
//  rates without relying on IINA audio output options.
//
//  Uses AVAudioFile (AVFoundation) to open and inspect the file's native
//  audio format, which avoids the need for IINA audio-exclusive/device options
//  and works for FLAC/WAV/AIFF/M4A and other AVFoundation-supported formats.
//

import Foundation
import AVFoundation
import CoreAudioTypes

struct AudioMetadata {
    let sampleRate: Double
    let bitDepth: Int?
    let codecDescription: String
}

enum AudioMetadataReader {
    /// Supported sample-rate window. Anything outside this range is treated as
    /// suspicious (corrupt metadata or non-audio file) and rejected.
    static let supportedSampleRateRange: ClosedRange<Double> = 8000...384000

    /// Reads audio metadata from a local file URL.
    /// - Returns: `AudioMetadata` when the file can be opened and reports a
    ///   plausible sample rate; `nil` for directories, missing files, or
    ///   unsupported/undecodable files.
    static func read(url: URL) -> AudioMetadata? {
        // Reject directories outright.
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else {
            return nil
        }

        // AVAudioFile(forReading:) throws for unsupported/corrupt files.
        guard let audioFile = try? AVAudioFile(forReading: url) else {
            return nil
        }

        // fileFormat describes the actual stored format of the file on disk
        // (as opposed to processingFormat, which is the converted format).
        let format = audioFile.fileFormat
        let sampleRate = format.sampleRate
        guard supportedSampleRateRange.contains(sampleRate) else { return nil }

        // Access the underlying AudioStreamBasicDescription for bit depth and
        // format ID. AVAudioFormat.streamDescription returns a pointer to the
        // canonical description.
        let desc = format.streamDescription.pointee
        let bitDepth: Int? = desc.mBitsPerChannel > 0 ? Int(desc.mBitsPerChannel) : nil
        let codecDescription = fourCharCodeToString(desc.mFormatID)

        return AudioMetadata(
            sampleRate: sampleRate,
            bitDepth: bitDepth,
            codecDescription: codecDescription
        )
    }

    /// Converts a FourCharCode (OSType) into a human-readable 4-character string,
    /// filtering non-printable bytes. Used purely for diagnostics.
    private static func fourCharCodeToString(_ code: UInt32) -> String {
        let bytes: [UInt8] = [
            UInt8((code >> 24) & 0xFF),
            UInt8((code >> 16) & 0xFF),
            UInt8((code >> 8) & 0xFF),
            UInt8(code & 0xFF)
        ]
        let printable = bytes.map { byte -> String in
            (0x20...0x7E).contains(byte) ? String(format: "%c", byte) : "?"
        }
        return printable.joined()
    }
}
