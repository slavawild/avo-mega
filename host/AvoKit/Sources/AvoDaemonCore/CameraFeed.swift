@preconcurrency import AVFoundation
import AvoIO
import AvoKit
import CoreImage
import CoreText
import Foundation
import ImageIO
import os
import UniformTypeIdentifiers

/// The Mac's side of Android's cameras (Settings › Devices › Cameras,
/// CameraSource; avo-vmm's camera.rs). When Android streams camera 0 (back)
/// or 1 (front), `camera <index> on <width> <height> <fps>` comes on the
/// event stream and the source chosen for it starts: one of this Mac's
/// cameras (its light is on only while Android uses it), or a scene drawn
/// here for an emulated one. Its frames go to avo-vmm as JPEG pictures of
/// exactly that size (the camera's picture cropped to fill it, turned as a
/// phone's sensor is: `sensorOrientation`), on a control
/// connection of their own (`camera feed`). `camera <index> off` stops it,
/// and a source chosen while a camera streams takes over at once.
///
/// macOS asks for camera access, in Avo's name, the first time Android uses
/// one of the Mac's cameras. Until it is allowed (or while the camera chosen
/// is gone and the Mac has none), Android sees a picture that says why.
public final class CameraFeed: @unchecked Sendable {
    /// How far both sensors are turned, as on a phone (GuestCamera's
    /// `<Orientation>`): Android asks for landscape frames and apps turn them
    /// a quarter clockwise to show them on the upright phone, and photos
    /// say so. Every source therefore sends its upright picture turned a
    /// quarter counterclockwise (`JPEGEncoder.sensorFrame`), so a portrait
    /// app sees a portrait camera: a phone video fills it, photos come out
    /// portrait. Avo's window shapes are not a turned phone to Android
    /// (its displays keep rotation 0), so a landscape window shows the same
    /// upright picture, cropped to its shape.
    public static let sensorOrientation = 90

    /// What Android asked a camera for.
    struct Request: Equatable, Sendable {
        let width: Int
        let height: Int
        let fps: Int
    }

    enum Event: Equatable {
        case on(camera: Int, Request)
        case off(camera: Int)
    }

    /// `camera <index> on <width> <height> <fps>` or `camera <index> off`.
    static func parse(_ line: String) -> Event? {
        let words = line.split(separator: " ")
        guard words.count >= 3, words[0] == "camera", let camera = Int(words[1]), (0..<2).contains(camera) else { return nil }
        switch words[2] {
        case "off": return .off(camera: camera)
        case "on":
            guard words.count == 6, let width = Int(words[3]), let height = Int(words[4]), let fps = Int(words[5]),
                  (16...8192).contains(width), (16...8192).contains(height), (1...120).contains(fps) else { return nil }
            return .on(camera: camera, Request(width: width, height: height, fps: fps))
        default: return nil
        }
    }

    /// avo-vmm's frame header: camera, width, height, length (u32 little endian).
    static func frame(camera: Int, request: Request, jpeg: Data) -> Data {
        var frame = Data(capacity: 16 + jpeg.count)
        for word in [camera, request.width, request.height, jpeg.count] {
            withUnsafeBytes(of: UInt32(word).littleEndian) { frame.append(contentsOf: $0) }
        }
        frame.append(jpeg)
        return frame
    }

    private let socketPath: String
    private let logger = Logger(subsystem: AvoIdentifiers.logSubsystem, category: "cameras")
    /// Sources, requests and producers change on `state` only.
    private let state = DispatchQueue(label: "com.avodroid.cameras")
    private var sources: [CameraSource]
    private var requests: [Int: Request] = [:]
    private var producers: [Int: any CameraProducer] = [:]
    private var stopped = false
    /// Frames go out on `output`, in order, over a blocking socket.
    private let output = DispatchQueue(label: "com.avodroid.cameras.feed")
    private var socket: Int32 = -1
    private var lastRefused: ContinuousClock.Instant?
    /// Frames waiting for `output`: past a few, new ones are dropped.
    private let lock = NSLock()
    private var backlog = 0
    /// A video source's movie started again from its beginning on this
    /// camera (Android began streaming it, asked for a new size, or chose
    /// the video while it streams), so its soundtrack can start over too.
    /// On `state`.
    private let videoStarted: (@Sendable (Int) -> Void)?
    /// How each video fills the picture (VMConfig.cameraVideoFraming): read
    /// by a playing video at every frame, so a change shows at once.
    private let framingLock = NSLock()
    private var framing: [String: VideoFraming]

    public init(socketPath: String, sources: [CameraSource], framing: [String: VideoFraming] = [:],
                videoStarted: (@Sendable (Int) -> Void)? = nil) {
        self.socketPath = socketPath
        self.sources = sources
        self.framing = framing
        self.videoStarted = videoStarted
    }

    /// How each video fills the picture now; a playing one follows at its next frame.
    public func useFraming(_ framing: [String: VideoFraming]) {
        framingLock.withLock { self.framing = framing }
    }

    func framing(of path: String) -> VideoFraming {
        framingLock.withLock { framing[path] } ?? VideoFraming()
    }

    /// A line of avo-vmm's event stream (others are ignored). How a stream
    /// went inside Android (`camerastats`, avo-vmm's virtio/media.rs) goes
    /// to the log beside what the Mac sent.
    public func handle(_ line: String) {
        if line.hasPrefix("camerastats ") {
            logger.notice("\(line, privacy: .public)")
            return
        }
        guard let event = Self.parse(line) else { return }
        state.async { [self] in
            switch event {
            case .on(let camera, let request):
                guard requests[camera] != request else { return }
                requests[camera] = request
            case .off(let camera):
                guard requests[camera] != nil else { return }
                requests[camera] = nil
            }
            switch event {
            case .on(let camera, _), .off(let camera): restart(camera)
            }
        }
    }

    /// The sources chosen now (back, front).
    public func use(_ sources: [CameraSource]) {
        state.async { [self] in
            let old = self.sources
            self.sources = sources
            for camera in sources.indices where camera >= old.count || old[camera] != sources[camera] {
                restart(camera)
            }
        }
    }

    public func stop() {
        state.sync {
            stopped = true
            for producer in producers.values { producer.stop() }
            producers = [:]
            requests = [:]
        }
        output.async { [self] in
            if socket >= 0 { Darwin.close(socket) }
            socket = -1
        }
    }

    /// On `state`: runs what camera `camera` should show now, nothing while
    /// Android does not stream it.
    private func restart(_ camera: Int) {
        producers.removeValue(forKey: camera)?.stop()
        guard !stopped, let request = requests[camera], camera < sources.count else { return }
        let deliver: @Sendable (Data) -> Void = { [weak self] jpeg in self?.send(camera, request, jpeg) }
        let producer: (any CameraProducer)?
        switch sources[camera] {
        case .none:
            producer = nil
        case .emulated:
            producer = DrawnCamera(.scene(camera: camera), request: request, deliver: deliver)
        case .mac(let id):
            producer = macCamera(id, camera: camera, request: request, deliver: deliver)
        case .video(let path):
            producer = FileVideoCamera(path: path, request: request, deliver: deliver) { [weak self] in
                self?.framing(of: path) ?? VideoFraming()
            }
        }
        logger.notice("camera \(camera, privacy: .public): \(request.width)×\(request.height) at \(request.fps) fps from \(self.sources[camera].rawValue, privacy: .public)")
        producers[camera] = producer
        producer?.start()
        if producer is FileVideoCamera { videoStarted?(camera) }
    }

    /// On `state`: the Mac's camera `id` (or its default one when that is
    /// gone), once the user allowed Avo to use it.
    private func macCamera(_ id: String, camera: Int, request: Request, deliver: @escaping @Sendable (Data) -> Void) -> (any CameraProducer)? {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            break
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                guard let self else { return }
                logger.notice("camera permission \(granted ? "allowed" : "denied", privacy: .public)")
                state.async { self.restart(camera) }
            }
            return DrawnCamera(.notice(.asking), request: request, deliver: deliver)
        default:
            return DrawnCamera(.notice(.denied), request: request, deliver: deliver)
        }
        guard let device = AVCaptureDevice(uniqueID: id) ?? AVCaptureDevice.default(for: .video) else {
            return DrawnCamera(.notice(.missing), request: request, deliver: deliver)
        }
        do {
            return try MacCamera(device: device, request: request, deliver: deliver)
        } catch {
            logger.error("camera \(camera, privacy: .public): \(device.localizedName, privacy: .public) did not start: \(String(describing: error), privacy: .public)")
            return DrawnCamera(.notice(.missing), request: request, deliver: deliver)
        }
    }

    /// From any producer's queue: queues one frame for avo-vmm.
    private func send(_ camera: Int, _ request: Request, _ jpeg: Data) {
        let accepted = lock.withLock {
            guard backlog < 3 else { return false }
            backlog += 1
            return true
        }
        guard accepted else { return }
        let frame = Self.frame(camera: camera, request: request, jpeg: jpeg)
        output.async { [self] in
            defer { lock.withLock { backlog -= 1 } }
            write(frame)
        }
    }

    /// On `output`: writes a frame, connecting first when needed. A frame
    /// that cannot go is dropped (avo-vmm sends gray meanwhile).
    private func write(_ frame: Data) {
        if socket < 0 {
            // An engine that refused the feed is asked again now and then, not for every frame.
            if let lastRefused, ContinuousClock.now - lastRefused < .seconds(2) { return }
            socket = Self.connectFeed(socketPath)
            if socket < 0 {
                lastRefused = .now
                return
            }
        }
        if !Self.writeAll(socket, frame) {
            Darwin.close(socket)
            socket = -1
        }
    }

    /// A control connection turned into the feed (`camera feed`, then `ok`).
    static func connectFeed(_ path: String) -> Int32 {
        guard let fd = try? UnixSocket.connect(path: path) else { return -1 }
        // A stuck engine fails a write instead of holding the queue for good.
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var answer = [UInt8]()
        var byte: UInt8 = 0
        guard writeAll(fd, Data("camera feed\n".utf8)) else { Darwin.close(fd); return -1 }
        while answer.count < 256, Darwin.read(fd, &byte, 1) == 1, byte != 0x0a { answer.append(byte) }
        guard answer == Array("ok".utf8) else { Darwin.close(fd); return -1 }
        return fd
    }

    static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { buffer in
            var sent = 0
            while sent < buffer.count {
                let n = Darwin.write(fd, buffer.baseAddress! + sent, buffer.count - sent)
                if n > 0 {
                    sent += n
                } else if n < 0 && errno == EINTR {
                    continue
                } else {
                    return false
                }
            }
            return true
        }
    }
}

/// Something that makes a camera's frames until it stops.
protocol CameraProducer: AnyObject, Sendable {
    func start()
    func stop()
}

/// JPEG pictures of exactly the size Android streams.
final class JPEGEncoder: @unchecked Sendable {
    private let context = CIContext(options: [.cacheIntermediates: false, .name: "Avo cameras"])
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private let quality = CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String)

    func jpeg(_ image: CIImage) -> Data? {
        context.jpegRepresentation(of: image, colorSpace: colorSpace, options: [quality: 0.8])
    }

    /// An upright picture as the turned sensor gives it (CameraFeed.sensorOrientation):
    /// filled into the portrait `height`×`width` the phone shows, then
    /// turned a quarter counterclockwise into the `width`×`height` frame
    /// Android asked for. Turned back a quarter clockwise, as apps do, it is
    /// upright again.
    static func sensorFrame(_ upright: CIImage, width: Int, height: Int, framing: VideoFraming = VideoFraming()) -> CIImage {
        placing(upright, width: height, height: width, framing: framing)
            .transformed(by: CGAffineTransform(translationX: CGFloat(width), y: 0).rotated(by: .pi / 2))
            .cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
    }

    /// `image` in `width`×`height` as `framing` says: covering it and
    /// cropped where its position says, or whole, centered on black.
    static func placing(_ image: CIImage, width: Int, height: Int, framing: VideoFraming) -> CIImage {
        let extent = image.extent
        let frame = CGRect(x: 0, y: 0, width: width, height: height)
        switch framing.mode {
        case .fill:
            let scale = max(CGFloat(width) / extent.width, CGFloat(height) / extent.height)
            // What is left over on the cropped side, spread by the position:
            // -1 keeps the left (top) edge, 1 the right (bottom) one.
            let along = CGFloat(framing.clampedPosition)
            let x = (extent.width * scale - CGFloat(width)) * (1 + along) / 2
            let y = (extent.height * scale - CGFloat(height)) * (1 - along) / 2
            return image
                .transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY)
                    .concatenating(CGAffineTransform(scaleX: scale, y: scale))
                    .concatenating(CGAffineTransform(translationX: -x, y: -y)))
                .cropped(to: frame)
        case .fit:
            let scale = min(CGFloat(width) / extent.width, CGFloat(height) / extent.height)
            let x = (CGFloat(width) - extent.width * scale) / 2
            let y = (CGFloat(height) - extent.height * scale) / 2
            return image
                .transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY)
                    .concatenating(CGAffineTransform(scaleX: scale, y: scale))
                    .concatenating(CGAffineTransform(translationX: x, y: y)))
                .composited(over: CIImage(color: .black).cropped(to: frame))
                .cropped(to: frame)
        }
    }

    /// `image` turned `quarterTurns` quarters clockwise (its extent moves;
    /// `placing` puts it back at the origin).
    static func turned(_ image: CIImage, quarterTurns: Int) -> CIImage {
        let turns = ((quarterTurns % 4) + 4) % 4
        guard turns != 0 else { return image }
        // y grows upward here: clockwise is a negative angle.
        return image.transformed(by: CGAffineTransform(rotationAngle: -CGFloat(turns) * .pi / 2))
    }

    /// `image` scaled to cover `width`×`height` and cropped to it, centered.
    static func filling(_ image: CIImage, width: Int, height: Int) -> CIImage {
        let extent = image.extent
        let scale = max(CGFloat(width) / extent.width, CGFloat(height) / extent.height)
        let x = (extent.width * scale - CGFloat(width)) / 2
        let y = (extent.height * scale - CGFloat(height)) / 2
        return image
            .transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY)
                .concatenating(CGAffineTransform(scaleX: scale, y: scale))
                .concatenating(CGAffineTransform(translationX: -x, y: -y)))
            .cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
    }
}

/// One of this Mac's cameras, at Android's size and at most its rate.
final class MacCamera: NSObject, CameraProducer, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "com.avodroid.cameras.capture")
    private let request: CameraFeed.Request
    private let deliver: @Sendable (Data) -> Void
    private let encoder = JPEGEncoder()
    /// When the next frame may go (on `queue`).
    private var due = CMTime.invalid

    init(device: AVCaptureDevice, request: CameraFeed.Request, deliver: @escaping @Sendable (Data) -> Void) throws {
        self.request = request
        self.deliver = deliver
        super.init()
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        // The smallest common preset that holds the portrait the phone shows
        // (Android's size turned, JPEGEncoder.sensorFrame); the picture is
        // cropped to it. Taller than any of them: the camera's best.
        let presets: [(AVCaptureSession.Preset, Int, Int)] = [(.vga640x480, 640, 480), (.hd1280x720, 1280, 720), (.hd1920x1080, 1920, 1080)]
        let preset = presets.first { $0.1 >= request.height && $0.2 >= request.width && session.canSetSessionPreset($0.0) }?.0 ?? .high
        if session.canSetSessionPreset(preset) { session.sessionPreset = preset }
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { throw AvoError.internalError("\(device.localizedName) is in use") }
        session.addInput(input)
        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(output) else { throw AvoError.internalError("\(device.localizedName) gives no video") }
        session.addOutput(output)
    }

    func start() {
        queue.async { self.session.startRunning() }
    }

    func stop() {
        queue.async { self.session.stopRunning() }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if due.isValid, time < due { return }
        // A little early is on time: the camera's own clock wobbles around Android's rate.
        let interval = CMTime(value: 1, timescale: CMTimeScale(request.fps))
        due = time + CMTimeMultiplyByFloat64(interval, multiplier: 0.8)
        guard let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let image = JPEGEncoder.sensorFrame(CIImage(cvPixelBuffer: pixels), width: request.width, height: request.height)
        if let jpeg = encoder.jpeg(image) { deliver(jpeg) }
    }
}

/// Loop a local video into the existing JPEG camera-feed protocol.
///
/// The movie is decoded in order by an AVAssetReader, as a player does,
/// rather than looked up frame by frame: a lookup decodes from the last key
/// frame every time, too slow for HD at Android's rate. On each tick of the
/// camera's clock the frame due at that moment of the movie is sent (the
/// last one again when the movie has no newer frame yet); at the movie's end
/// (`asset.duration`, where its soundtrack sidecar ends too) the reader
/// starts over from the beginning. A slow tick decodes the frames it missed
/// without sending them, so the picture never falls behind real time.
/// The asset is never played with audio.
final class FileVideoCamera: CameraProducer, @unchecked Sendable {
    /// What the reader needs, loaded once with AVFoundation's async API.
    private struct Movie {
        let track: AVAssetTrack
        /// Seconds; the loop's length.
        let duration: Double
        let orientation: CGImagePropertyOrientation
        /// As recorded, before `orientation` turns it upright.
        let naturalSize: CGSize
    }

    /// A decoded picture handed to the encoder's queue (read only there).
    private struct Pixels: @unchecked Sendable {
        let buffer: CVPixelBuffer
    }

    private let asset: AVURLAsset
    private let request: CameraFeed.Request
    private let deliver: @Sendable (Data) -> Void
    /// Turning, framing and JPEG encoding run on a queue of their own, so
    /// the clock and the decoding on `queue` never wait for them: a frame
    /// whose encoding is not done yet is replaced by the last one sent.
    private let encoder = JPEGEncoder()
    private let encodeQueue = DispatchQueue(label: "com.avodroid.cameras.video.encode")
    private let clock = ContinuousClock()
    private let logger = Logger(subsystem: AvoIdentifiers.logSubsystem, category: "cameras")
    /// Everything below changes on `queue` only.
    private let queue = DispatchQueue(label: "com.avodroid.cameras.video")
    /// A picture is on `encodeQueue`; a newer one waits for the next tick.
    private var encoding = false
    private var newPixels = false
    /// Decode at the size the camera needs (`decodeSize`); off when this
    /// movie's decoder refused to scale, so it decodes as recorded.
    private var scaledDecoding = true
    /// What the log says every five seconds (category "cameras"): frames
    /// sent and newly encoded, and the time decoding and encoding took.
    private var stats = (sent: 0, encoded: 0, decode: Duration.zero, encode: Duration.zero)
    private var statsSince: ContinuousClock.Instant?
    private var stopped = false
    private var movie: Movie?
    private var timer: DispatchSourceTimer?
    private var reader: AVAssetReader?
    private var output: AVAssetReaderTrackOutput?
    /// When the current loop's 0 s was.
    private var loopStart: ContinuousClock.Instant?
    /// A decoded frame that is not due yet.
    private var next: CMSampleBuffer?
    /// The frame sent last, sent again until a newer one is due.
    private var last: Data?
    /// The picture `last` came from, and how it was framed: encoded again
    /// when the framing changes, even while the movie shows no new frame.
    private var lastPixels: CVPixelBuffer?
    private var lastFraming: VideoFraming?
    /// How the movie fills the picture now (CameraFeed.useFraming).
    private let framing: @Sendable () -> VideoFraming

    init(path: String, request: CameraFeed.Request, deliver: @escaping @Sendable (Data) -> Void,
         framing: @escaping @Sendable () -> VideoFraming = { VideoFraming() }) {
        self.asset = AVURLAsset(url: URL(fileURLWithPath: path))
        self.request = request
        self.deliver = deliver
        self.framing = framing
    }

    func start() {
        let asset = self.asset
        Task { [weak self] in
            // Missing, corrupt or unsupported video: nothing is sent, and the
            // VM keeps its own gray fallback.
            guard let track = try? await asset.loadTracks(withMediaType: .video).first,
                  let duration = try? await asset.load(.duration), duration.isNumeric, duration.seconds > 0,
                  let transform = try? await track.load(.preferredTransform),
                  let naturalSize = try? await track.load(.naturalSize)
            else { return }
            let movie = Movie(track: track, duration: duration.seconds, orientation: Self.orientation(transform),
                              naturalSize: naturalSize)
            guard let self else { return }
            queue.async { self.begin(movie) }
        }
    }

    func stop() {
        queue.sync {
            stopped = true
            timer?.cancel()
            timer = nil
            reader?.cancelReading()
            reader = nil
            output = nil
            next = nil
            lastPixels = nil
        }
    }

    /// On `queue`: the movie is loaded; it plays from its beginning now.
    private func begin(_ movie: Movie) {
        guard !stopped else { return }
        self.movie = movie
        loopStart = clock.now
        rewind()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .nanoseconds(1_000_000_000 / max(request.fps, 1)), leeway: .milliseconds(3))
        timer.setEventHandler { [weak self] in self?.tick() }
        self.timer = timer
        timer.resume()
    }

    /// On `queue`: a new reader at the movie's beginning.
    private func rewind() {
        reader?.cancelReading()
        reader = nil
        output = nil
        next = nil
        guard let movie, let reader = try? AVAssetReader(asset: asset) else { return }
        var settings: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        let size = scaledDecoding ? Self.decodeSize(natural: movie.naturalSize, orientation: movie.orientation, request: request) : nil
        if let size {
            // The decoder scales (in hardware where it can): a 4K movie is
            // not decoded at 4K for a 720p camera.
            settings[kCVPixelBufferWidthKey as String] = Int(size.width)
            settings[kCVPixelBufferHeightKey as String] = Int(size.height)
        }
        let output = AVAssetReaderTrackOutput(track: movie.track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return refuseScaling(size) }
        reader.add(output)
        guard reader.startReading() else { return refuseScaling(size) }
        self.reader = reader
        self.output = output
    }

    /// On `queue`: a reader that would not decode at `size` starts again
    /// decoding as recorded (once; nothing more to try without a size).
    private func refuseScaling(_ size: CGSize?) {
        guard size != nil, scaledDecoding else { return }
        logger.notice("camera video: the decoder does not scale this movie; it decodes at its own size")
        scaledDecoding = false
        rewind()
    }

    /// The size to decode a movie at: as small as the portrait the phone
    /// shows (Android's frame turned, JPEGEncoder.sensorFrame) allows while
    /// still covering it whichever way the movie is turned, in its own
    /// (unturned) orientation, even sides; nil when the movie is no bigger
    /// than that.
    static func decodeSize(natural: CGSize, orientation: CGImagePropertyOrientation, request: CameraFeed.Request) -> CGSize? {
        guard natural.width > 0, natural.height > 0 else { return nil }
        // The framing can turn the video a quarter at any time without a
        // new reader (VideoFraming.rotation): cover the portrait either way.
        let covering = { (picture: CGSize) in
            max(CGFloat(request.height) / picture.width, CGFloat(request.width) / picture.height)
        }
        let scale = max(covering(natural), covering(CGSize(width: natural.height, height: natural.width)))
        guard scale < 1 else { return nil }
        // Nearest even side (rounding up could turn 1280.0000001 into 1282).
        func even(_ side: CGFloat) -> CGFloat { max(16, (side / 2).rounded() * 2) }
        return CGSize(width: even(natural.width * scale), height: even(natural.height * scale))
    }

    /// On `queue`, once per frame Android wants.
    private func tick() {
        guard !stopped, let movie, var loopStart else { return }
        let elapsed = loopStart.duration(to: clock.now)
        var seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        if seconds >= movie.duration {
            // The movie's end: the next loop starts where this one ended
            // (more than one when the clock jumped, as after a sleep).
            let loops = (seconds / movie.duration).rounded(.down)
            loopStart = loopStart.advanced(by: .seconds(loops * movie.duration))
            self.loopStart = loopStart
            seconds -= loops * movie.duration
            rewind()
        }
        let decodeStart = clock.now
        if let frame = latestFrame(upTo: seconds) {
            lastPixels = frame
            newPixels = true
            stats.decode += decodeStart.duration(to: clock.now)
        }
        let framing = self.framing()
        if !encoding, newPixels || framing != lastFraming, let pixels = lastPixels {
            // The encoder sends this tick's frame when it is done.
            newPixels = false
            encoding = true
            startEncoding(Pixels(buffer: pixels), movie.orientation, framing)
        } else if let last {
            deliver(last)
            stats.sent += 1
        }
        reportStats()
    }

    /// On `queue`: hands a picture to `encodeQueue`, which turns, frames and
    /// encodes it, then sends it from `queue` (not after `stop`).
    private func startEncoding(_ pixels: Pixels, _ orientation: CGImagePropertyOrientation, _ framing: VideoFraming) {
        encodeQueue.async { [self] in
            let start = clock.now
            let jpeg = encode(pixels.buffer, orientation, framing)
            let took = start.duration(to: clock.now)
            queue.async { [self] in
                encoding = false
                guard !stopped else { return }
                stats.encode += took
                guard let jpeg else { return }
                last = jpeg
                lastFraming = framing
                deliver(jpeg)
                stats.sent += 1
                stats.encoded += 1
            }
        }
    }

    /// On `queue`: every five seconds, what the camera sent and what that took.
    private func reportStats() {
        let now = clock.now
        guard let since = statsSince else {
            statsSince = now
            return
        }
        let elapsed = since.duration(to: now)
        guard elapsed >= .seconds(5) else { return }
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        func ms(_ total: Duration, _ count: Int) -> String {
            let value = (Double(total.components.seconds) * 1000 + Double(total.components.attoseconds) / 1e15) / Double(max(count, 1))
            return String(format: "%.1f", value)
        }
        let fps = String(format: "%.1f", Double(stats.sent) / seconds), newFPS = String(format: "%.1f", Double(stats.encoded) / seconds)
        let decodeMs = ms(stats.decode, stats.encoded), encodeMs = ms(stats.encode, stats.encoded)
        let asked = "\(request.fps) fps at \(request.width)×\(request.height)"
        logger.notice("camera video: \(fps, privacy: .public) fps sent (\(newFPS, privacy: .public) new) for \(asked, privacy: .public); decode \(decodeMs, privacy: .public) ms, encode \(encodeMs, privacy: .public) ms a frame")
        stats = (0, 0, .zero, .zero)
        statsSince = now
    }

    /// On `queue`: decodes up to `seconds` into the movie and returns the
    /// latest frame due by then, nil when none newer than the last is due.
    private func latestFrame(upTo seconds: Double) -> CVPixelBuffer? {
        var due: CVPixelBuffer?
        while true {
            if next == nil {
                // At the end of the movie the reader is done, and asking it
                // again raises (its status is no longer reading): the last
                // frame stays up until the loop starts over.
                guard let reader, reader.status == .reading else { break }
                guard let sample = output?.copyNextSampleBuffer() else {
                    // A decoder that took the size but cannot scale fails here.
                    if reader.status == .failed, scaledDecoding {
                        scaledDecoding = false
                        logger.notice("camera video: decoding at the camera's size failed (\(String(describing: reader.error), privacy: .public)); decoding at the movie's own size")
                        rewind()
                        continue
                    }
                    break
                }
                next = sample
            }
            guard let sample = next else { break }
            let time = CMSampleBufferGetPresentationTimeStamp(sample)
            if time.isNumeric, time.seconds > seconds { break }
            next = nil
            if let pixels = CMSampleBufferGetImageBuffer(sample) { due = pixels }
        }
        return due
    }

    private func encode(_ pixels: CVPixelBuffer, _ orientation: CGImagePropertyOrientation, _ framing: VideoFraming) -> Data? {
        let image = JPEGEncoder.turned(CIImage(cvPixelBuffer: pixels).oriented(orientation), quarterTurns: framing.quarterTurns)
        return encoder.jpeg(JPEGEncoder.sensorFrame(image, width: request.width, height: request.height, framing: framing))
    }

    /// A track's preferred transform (how a player turns its picture
    /// upright) as an image orientation: phones record portrait movies
    /// sideways and say so here.
    static func orientation(_ transform: CGAffineTransform) -> CGImagePropertyOrientation {
        switch (transform.a, transform.b, transform.c, transform.d) {
        case (0, 1, -1, 0): .right
        case (0, -1, 1, 0): .left
        case (-1, 0, 0, -1): .down
        default: .up
        }
    }
}

/// A picture drawn here at Android's rate: an emulated camera's scene, or a
/// notice of why the Mac's camera is not there.
final class DrawnCamera: CameraProducer, @unchecked Sendable {
    enum Notice {
        /// macOS is asking the user.
        case asking
        /// The user did not allow Avo to use the camera.
        case denied
        /// The chosen camera is gone, and the Mac has no other.
        case missing
    }

    enum Picture {
        case scene(camera: Int)
        case notice(Notice)
    }

    private let picture: Picture
    private let request: CameraFeed.Request
    private let deliver: @Sendable (Data) -> Void
    private let timer: DispatchSourceTimer
    private let started = Date()

    init(_ picture: Picture, request: CameraFeed.Request, deliver: @escaping @Sendable (Data) -> Void) {
        self.picture = picture
        self.request = request
        self.deliver = deliver
        timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "com.avodroid.cameras.drawn"))
        // A notice changes little: twice a second keeps avo-vmm from going gray.
        let fps: Int
        switch picture {
        case .scene: fps = request.fps
        case .notice: fps = min(request.fps, 2)
        }
        timer.schedule(deadline: .now(), repeating: .nanoseconds(1_000_000_000 / max(fps, 1)), leeway: .milliseconds(2))
        timer.setEventHandler { [weak self] in self?.tick() }
    }

    func start() {
        timer.resume()
    }

    func stop() {
        timer.cancel()
    }

    private func tick() {
        guard let image = Self.draw(picture, width: request.width, height: request.height, time: Date().timeIntervalSince(started), turned: true),
              let jpeg = Self.jpeg(image) else { return }
        deliver(jpeg)
    }

    static func jpeg(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    /// A `width`×`height` picture; `turned`, as the turned sensor gives it
    /// (JPEGEncoder.sensorFrame): drawn upright on the portrait
    /// `height`×`width` and turned a quarter counterclockwise.
    static func draw(_ picture: Picture, width: Int, height: Int, time: TimeInterval, turned: Bool = false) -> CGImage? {
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        var (w, h) = (CGFloat(width), CGFloat(height))
        if turned {
            // A point (x, y) of the upright picture lands at (width - y, x).
            context.translateBy(x: w, y: 0)
            context.rotate(by: .pi / 2)
            (w, h) = (h, w)
        }
        switch picture {
        case .scene(let camera):
            drawScene(context, w, h, time: time, camera: camera)
        case .notice(let notice):
            context.setFillColor(CGColor(srgbRed: 0.11, green: 0.11, blue: 0.12, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: w, height: h))
            let (title, detail) = text(notice)
            drawText(title, context, in: CGRect(x: w * 0.08, y: h * 0.5, width: w * 0.84, height: h * 0.2),
                     size: h * 0.065, color: CGColor(gray: 1, alpha: 1))
            drawText(detail, context, in: CGRect(x: w * 0.08, y: h * 0.2, width: w * 0.84, height: h * 0.28),
                     size: h * 0.042, color: CGColor(gray: 0.7, alpha: 1))
        }
        return context.makeImage()
    }

    /// A sky with a sun that crosses it every 20 seconds over hills, the
    /// camera's name and the time: enough to see a camera work, which one it
    /// is, and that it moves.
    private static func drawScene(_ context: CGContext, _ w: CGFloat, _ h: CGFloat, time: TimeInterval, camera: Int) {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let sky = [CGColor(srgbRed: 0.16, green: 0.42, blue: 0.69, alpha: 1), CGColor(srgbRed: 0.62, green: 0.82, blue: 0.95, alpha: 1)]
        if let gradient = CGGradient(colorsSpace: space, colors: sky as CFArray, locations: [0, 1]) {
            context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: h), end: CGPoint(x: 0, y: h * 0.3), options: [.drawsAfterEndLocation])
        }
        let phase = time.truncatingRemainder(dividingBy: 20) / 20
        let radius = h * 0.09
        let sun = CGPoint(x: -radius + (w + 2 * radius) * phase, y: h * (0.55 + 0.25 * sin(.pi * phase)))
        context.setFillColor(CGColor(srgbRed: 0.98, green: 0.85, blue: 0.35, alpha: 1))
        context.fillEllipse(in: CGRect(x: sun.x - radius, y: sun.y - radius, width: radius * 2, height: radius * 2))
        for (index, shade) in [0.42, 0.33].enumerated() {
            let hill = CGMutablePath()
            hill.move(to: CGPoint(x: 0, y: 0))
            for step in 0...40 {
                let x = w * CGFloat(step) / 40
                let y = h * (0.28 - 0.06 * CGFloat(index)) + h * 0.05 * sin(Double(step) / 40 * .pi * (2.2 + Double(index)) + Double(index))
                hill.addLine(to: CGPoint(x: x, y: y))
            }
            hill.addLine(to: CGPoint(x: w, y: 0))
            hill.closeSubpath()
            context.setFillColor(CGColor(srgbRed: 0.18, green: shade + 0.1, blue: 0.24, alpha: 1))
            context.addPath(hill)
            context.fillPath()
        }
        let name = camera == 0 ? String(localized: "Back camera", bundle: .avoKit) : String(localized: "Front camera", bundle: .avoKit)
        let clock = Date().formatted(date: .omitted, time: .standard)
        drawText("Avo · \(name)", context, in: CGRect(x: w * 0.05, y: h * 0.78, width: w * 0.9, height: h * 0.16),
                 size: h * 0.07, color: CGColor(gray: 1, alpha: 1), centered: false)
        drawText(clock, context, in: CGRect(x: w * 0.05, y: h * 0.68, width: w * 0.9, height: h * 0.1),
                 size: h * 0.05, color: CGColor(gray: 1, alpha: 0.85), centered: false)
    }

    private static func text(_ notice: Notice) -> (String, String) {
        switch notice {
        case .asking:
            (String(localized: "Avo is asking to use the camera", bundle: .avoKit),
             String(localized: "Answer macOS’s question to see the Mac’s camera here.", bundle: .avoKit))
        case .denied:
            (String(localized: "Avo can’t use the Mac’s camera", bundle: .avoKit),
             String(localized: "Allow Avo in System Settings › Privacy & Security › Camera, or choose another camera in Avo › Settings › Devices.", bundle: .avoKit))
        case .missing:
            (String(localized: "The camera isn’t connected", bundle: .avoKit),
             String(localized: "Connect it again, or choose another camera in Avo › Settings › Devices.", bundle: .avoKit))
        }
    }

    private static func drawText(_ text: String, _ context: CGContext, in rect: CGRect, size: CGFloat, color: CGColor, centered: Bool = true) {
        let font = CTFontCreateUIFontForLanguage(.system, size, nil) ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
        var alignment = centered ? CTTextAlignment.center : CTTextAlignment.left
        let style = withUnsafeBytes(of: &alignment) { bytes in
            var setting = CTParagraphStyleSetting(spec: .alignment, valueSize: MemoryLayout<CTTextAlignment>.size, value: bytes.baseAddress!)
            return CTParagraphStyleCreate(&setting, 1)
        }
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
            NSAttributedString.Key(kCTParagraphStyleAttributeName as String): style,
        ]
        let framesetter = CTFramesetterCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), CGPath(rect: rect, transform: nil), nil)
        CTFrameDraw(frame, context)
    }
}
