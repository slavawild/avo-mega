import AVFoundation
import Foundation
import CoreMedia

/// Decode an imported movie soundtrack once into an immutable sidecar PCM file.
/// avo-vmm memory maps this file for its virtio-sound capture stream.
/// Output: 48,000 Hz, interleaved stereo, signed 16-bit little endian.
enum VideoAudioExtractor {
    /// Returns false when the movie has no sound track; the camera still works.
    nonisolated static func createSidecar(for video: URL) throws -> Bool {
        let asset = AVURLAsset(url: video)
        guard let track = asset.tracks(withMediaType: .audio).first else { return false }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48_000,
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
            try file.write(contentsOf: data)
        }
        guard reader.status == .completed else {
            throw reader.error ?? NSError(domain: "AvoVideoAudio", code: 3)
        }
        try file.close()
        let count = try FileManager.default.attributesOfItem(atPath: temporary.path)[.size] as? NSNumber
        guard let size = count?.intValue, size >= 4, size % 4 == 0 else { return false }
        try FileManager.default.moveItem(at: temporary, to: sidecar)
        return true
    }
}
