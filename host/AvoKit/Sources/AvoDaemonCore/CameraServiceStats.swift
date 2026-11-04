import Foundation

/// What Android's cameraserver says of the streams an app has open
/// (`dumpsys media.camera`, Camera3OutputStream's dump): the frames the
/// camera HAL produced for each, so the log (category "cameras") can say
/// how many a second reach the app's preview and its recording, beside
/// what the Mac sent (CameraFeed) and what Android took (`camerastats`).
struct CameraServiceStats: Equatable {
    struct Stream: Equatable {
        /// `<camera>/<stream>`: the camera device and the stream's number on it.
        let key: String
        /// "640x480 0x22 SurfaceTexture-…": its size, format and consumer.
        let description: String
        let frames: Int
    }

    let streams: [Stream]
    let at: ContinuousClock.Instant

    init(dump: String, at: ContinuousClock.Instant) {
        self.at = at
        var streams: [Stream] = []
        var camera = "?"
        var index: String?
        var consumer = "", dims = ""
        func flush(frames: Int) {
            guard let index else { return }
            let description = [dims, consumer].filter { !$0.isEmpty }.joined(separator: " ")
            streams.append(Stream(key: "\(camera)/\(index)", description: description, frames: frames))
        }
        for raw in dump.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("== Camera device "), let id = line.dropFirst("== Camera device ".count).split(separator: " ").first {
                // "== Camera device 1 dynamic info: =="
                camera = String(id)
                index = nil
            } else if line.hasPrefix("Device ") && line.hasSuffix("is open. Client instance dump:") {
                // "Device 1 is open. Client instance dump:" (newer cameraservers).
                camera = String(line.dropFirst("Device ".count).split(separator: " ").first ?? "?")
                index = nil
            } else if line.hasPrefix("Stream["), let close = line.firstIndex(of: "]") {
                // "Stream[0]: Output"
                index = String(line[line.index(line.startIndex, offsetBy: 7)..<close])
                consumer = ""
                dims = ""
            } else if index != nil, line.hasPrefix("Consumer name: ") {
                consumer = String(line.dropFirst("Consumer name: ".count))
            } else if index != nil, line.hasPrefix("Dims: ") {
                // "Dims: 640 x 480, format 0x22, dataspace 0x0"
                let parts = line.dropFirst("Dims: ".count).split(separator: ",")
                let size = parts.first.map { $0.replacingOccurrences(of: " ", with: "") } ?? ""
                let format = parts.dropFirst().first?.split(separator: " ").last.map(String.init) ?? ""
                dims = [size, format].filter { !$0.isEmpty }.joined(separator: " ")
            } else if index != nil, line.hasPrefix("Frames produced: ") {
                // "Frames produced: 1234, last timestamp: 5678 ns"
                let number = line.dropFirst("Frames produced: ".count).prefix { $0.isNumber }
                if let frames = Int(number) { flush(frames: frames) }
                index = nil
            }
        }
        self.streams = streams
    }

    /// Each stream's frames a second since `earlier`, for the streams both
    /// saw (a stream that started over counts from zero); nil with none.
    func report(since earlier: CameraServiceStats) -> String? {
        let elapsed = earlier.at.duration(to: at)
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        guard seconds > 0 else { return nil }
        let before = Dictionary(earlier.streams.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        let parts = streams.compactMap { stream -> String? in
            guard let old = before[stream.key], old.description == stream.description else { return nil }
            let produced = stream.frames >= old.frames ? stream.frames - old.frames : stream.frames
            return "camera \(stream.key) \(stream.description): \(String(format: "%.1f", Double(produced) / seconds)) fps"
        }
        return parts.isEmpty ? nil : "android streams: " + parts.joined(separator: "; ")
    }
}
