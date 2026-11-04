import AVFoundation
import Foundation
import CoreMedia

/// Decode an imported movie soundtrack once into an immutable sidecar PCM file.
/// avo-vmm memory maps this file for its virtio-sound capture stream.
/// Output: 48,000 Hz, interleaved stereo, signed 16-bit little endian.
///
/// The sidecar is laid out on the movie's own timeline: frame N is the sound
/// at N / 48,000 s into the movie, and the file is exactly as long as the
/// movie (`asset.duration`, where FileVideoCamera wraps the picture). A
/// soundtrack that starts late gets silence in front, one that ends early
/// gets silence after, and anything past the movie's end is left out, so the
/// sound and the picture loop together and never drift apart.
enum VideoAudioExtractor {
    nonisolated static let rate: Int32 = 48_000
    /// Interleaved stereo S16LE.
    nonisolated static let frameBytes = 4

    /// Returns false when the movie has no sound track; the camera still works.
    nonisolated static func createSidecar(for video: URL) throws -> Bool {
        let asset = AVURLAsset(url: video)
        guard let track = asset.tracks(withMediaType: .audio).first else { return false }
        let duration = asset.duration
        guard duration.isNumeric, duration.seconds > 0 else { return false }
        let totalFrames = frames(at: duration)
        guard totalFrames > 0 else { return false }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: rate,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        guard reader.canAdd(output) else {
            throw NSError(domain: "AvoVideoAudio", code: 1, userInfo: [NSLocalizedDescriptionKey: "This movie's audio cannot be decoded."])
        }
        reader.add(output)
        let sidecar = video.deletingPathExtension().appendingPathExtension("pcm")
        let temporary = video.deletingPathExtension().appendingPathExtension("pcm-part")
        FileManager.default.createFile(atPath: temporary.path, contents: nil)
        let file = try FileHandle(forWritingTo: temporary)
        defer {
            try? file.close()
            try? FileManager.default.removeItem(at: temporary)
        }
        guard reader.startReading() else {
            throw reader.error ?? NSError(domain: "AvoVideoAudio", code: 2)
        }
        /// Frames written so far, from the movie's start.
        var written = 0
        /// Frames of the soundtrack itself (not silence) written.
        var heard = 0
        func writeSilence(_ count: Int) throws {
            var remaining = count
            let second = Data(count: Int(rate) * frameBytes)
            while remaining > 0 {
                let chunk = min(remaining, Int(rate))
                try file.write(contentsOf: second.prefix(chunk * frameBytes))
                remaining -= chunk
            }
        }
        while let buffer = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            guard length > 0 else { continue }
            var data = Data(count: length)
            let status = data.withUnsafeMutableBytes { bytes -> OSStatus in
                guard let address = bytes.baseAddress else { return -1 }
                return CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: address)
            }
            guard status == noErr else {
                reader.cancelReading()
                throw NSError(domain: "AvoVideoAudio", code: Int(status), userInfo: [NSLocalizedDescriptionKey: "Could not read the movie's decoded audio samples."])
            }
            // Where this buffer belongs on the movie's timeline: a gap before
            // it is silence, a part before what is already written is dropped.
            let timestamp = CMSampleBufferGetPresentationTimeStamp(buffer)
            let start = timestamp.isNumeric ? frames(at: timestamp) : written
            var skip = 0
            if start > written {
                let gap = min(start, totalFrames) - written
                try writeSilence(gap)
                written += gap
            } else if start < written {
                skip = written - start
            }
            let available = data.count / frameBytes - skip
            let count = min(available, totalFrames - written)
            // Past the movie's end: read on so the reader completes, keep nothing.
            guard count > 0 else { continue }
            try file.write(contentsOf: data.subdata(in: skip * frameBytes ..< (skip + count) * frameBytes))
            written += count
            heard += count
        }
        guard reader.status == .completed else {
            throw reader.error ?? NSError(domain: "AvoVideoAudio", code: 3)
        }
        guard heard > 0 else { return false }
        if written < totalFrames { try writeSilence(totalFrames - written) }
        try file.close()
        try FileManager.default.moveItem(at: temporary, to: sidecar)
        return true
    }

    /// `time` on the movie's timeline in 48 kHz frames.
    nonisolated static func frames(at time: CMTime) -> Int {
        Int(CMTimeConvertScale(time, timescale: rate, method: .roundHalfAwayFromZero).value)
    }
}
