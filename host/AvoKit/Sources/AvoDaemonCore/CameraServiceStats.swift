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
        // The dump can list a stream twice (the device's configuration and
        // its client's): each listing counts on its own, by its turn.
        var seen: [String: Int] = [:]
        func flush(frames: Int) {
            guard let index else { return }
            let description = [dims, consumer].filter { !$0.isEmpty }.joined(separator: " ")
            var key = "\(camera)/\(index)"
            let turn = (seen[key] ?? 0) + 1
            seen[key] = turn
            if turn > 1 { key += "#\(turn)" }
            streams.append(Stream(key: key, description: description, frames: frames))
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

    /// The threads that took the most CPU in the last frame of toybox's
    /// `top -H -b` (`ThreadLoad.command`): "busiest threads: 85% ExtCamOutThr
    /// (android.hardware.camera.provider…), …", those at 5% or more; nil
    /// with none. Which part of Android a slow camera waits on.
    static func busiestThreads(top output: String, limit: Int = 8) -> String? {
        let lines = output.split(separator: "\n").map(String.init)
        // The last frame starts after the last header (it names %CPU).
        guard let header = lines.lastIndex(where: { $0.contains("%CPU") }) else { return nil }
        var rows: [(cpu: Double, text: String)] = []
        for line in lines[(header + 1)...] {
            // PID USER PR NI VIRT RES SHR S %CPU %MEM TIME+ THREAD PROCESS
            let fields = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard fields.count >= 12, let cpu = Double(fields[8]), cpu >= 5 else { continue }
            let thread = fields[11]
            let process = fields.count > 12 ? fields[12...].joined(separator: " ") : ""
            rows.append((cpu, process.isEmpty ? thread : "\(thread) (\(process))"))
        }
        guard !rows.isEmpty else { return nil }
        let busiest = rows.sorted { $0.cpu > $1.cpu }.prefix(limit)
        return "busiest threads: " + busiest.map { "\(Int($0.cpu.rounded()))% \($0.text)" }.joined(separator: ", ")
    }

    /// Two frames a second apart (the first counts from each thread's
    /// start), threads by CPU, enough lines for the busiest.
    static let threadLoadCommand = "top -H -b -n 2 -d 1 -m 40"
}

/// Android's warnings and errors while a camera streams (`logcat -v epoch`,
/// W and up), since the last look: what the camera HAL, cameraserver, a
/// codec or the app says when frames go missing that every count above
/// still calls delivered. Like messages (numbers aside) count once, the
/// commonest first: "android warnings: 12× E ExtCamOutThr: Convert V4L2
/// frame to YU12 failed! res -1; …".
enum AndroidWarnings {
    /// Tags whose warnings come with or without a camera (MediaProvider's
    /// on every file an app writes; services this Android image lacks).
    static let quiet: Set<String> = ["MediaProvider", "libbinder.ServiceManagerCppClient", "libc", "init", "DevicePolicyManager"]

    /// The first look takes the newest 300 lines; later ones those since `since`.
    static func command(since: String?) -> String {
        "logcat -d -v epoch " + (since.map { "-t '\($0)'" } ?? "-t 300") + " '*:W'"
    }

    /// The report (nil with none) and the newest line's time, for the next
    /// look's `since`. Lines at or before `since` were reported already.
    static func report(logcat output: String, since: String?, limit: Int = 8) -> (report: String?, last: String?) {
        let after = since.flatMap(Double.init)
        var last = since
        var groups: [String: (level: String, tag: String, message: String, count: Int, order: Int)] = [:]
        for raw in output.split(separator: "\n") {
            // "1730800000.123  1234  1250 W Tag     : message"
            let fields = raw.split(separator: " ", maxSplits: 4, omittingEmptySubsequences: true)
            guard fields.count == 5, let time = Double(fields[0]), ["W", "E", "F"].contains(fields[3]) else { continue }
            if let after, time <= after { continue }
            last = String(fields[0])
            let rest = fields[4]
            guard let colon = rest.firstIndex(of: ":") else { continue }
            let tag = rest[..<colon].trimmingCharacters(in: .whitespaces)
            var message = rest[rest.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            // Stack traces, and services that complain whatever the camera does.
            if message.hasPrefix("at ") || message.hasPrefix("Caused by") || message.hasPrefix("... ") || quiet.contains(tag) { continue }
            if message.count > 160 { message = String(message.prefix(160)) + "…" }
            let shape = message.replacingOccurrences(of: "[0-9]+", with: "#", options: .regularExpression)
            let key = "\(fields[3]) \(tag) \(shape)"
            if let group = groups[key] {
                groups[key]?.count = group.count + 1
            } else {
                groups[key] = (String(fields[3]), tag, message, 1, groups.count)
            }
        }
        guard !groups.isEmpty else { return (nil, last) }
        let commonest = groups.values.sorted { ($0.count, -$0.order) > ($1.count, -$1.order) }.prefix(limit)
        let parts = commonest.map { "\($0.count)× \($0.level) \($0.tag): \($0.message)" }
        let more = groups.count > limit ? " (and \(groups.count - limit) more kinds)" : ""
        return ("android warnings: " + parts.joined(separator: "; ") + more, last)
    }
}
