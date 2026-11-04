@preconcurrency import AVFoundation
import AvoIO
import AvoKit
import CoreImage
import CryptoKit
import Foundation
import ImageIO
import Testing
@testable import AvoDaemonCore

@Suite struct CameraSettingsTests {
    /// Each video's framing is kept by its path, applies at once, and a
    /// framing this Avo does not know leaves videos filling, centered.
    @Test func videoFramingIsKeptPerVideo() throws {
        var config = VMConfig()
        let old = config
        config.cameraVideoFraming["/Videos/1/clip.mov"] = VideoFraming(mode: .fit)
        config.cameraVideoFraming["/Videos/2/wide.mp4"] = VideoFraming(mode: .fill, position: -0.5)
        #expect(config.effect(of: old) == .immediate)
        let decoded = try JSONDecoder().decode(VMConfig.self, from: JSONEncoder().encode(config))
        #expect(decoded.cameraVideoFraming == config.cameraVideoFraming)
        let unknown = Data(#"{"cameraVideoFraming": {"/a.mov": {"mode": "zoom", "position": 0}}}"#.utf8)
        #expect(try JSONDecoder().decode(VMConfig.self, from: unknown).cameraVideoFraming == [:])
        #expect(VideoFraming(position: 7).clampedPosition == 1 && VideoFraming(position: -.infinity).clampedPosition == 0)
    }

    /// Whose sound Android's microphone hears: the front camera's video,
    /// else the back one's, only with the microphone on and set to it.
    @Test func theMicrophoneHearsTheFrontVideoFirst() {
        let front = "/Videos/1/Front clip.mov", back = "/Videos/2/back.mp4"
        var config = VMConfig(backCamera: .video(back), frontCamera: .video(front), microphoneVideoAudio: true)
        #expect(config.soundtrackCamera == 1)
        #expect(config.videoMicrophonePCMPath == "/Videos/1/Front clip.pcm")
        #expect(VMMEngine.videoMicrophoneCommand(config) == "microphone file /Videos/1/Front clip.pcm")
        config.frontCamera = .emulated
        #expect(config.soundtrackCamera == 0)
        #expect(config.videoMicrophonePCMPath == "/Videos/2/back.pcm")
        // The Mac's microphone: set to it, with no video, with cameras off,
        // and (as silence follows anyway) with the microphone off.
        let changes: [(inout VMConfig) -> Void] = [{ $0.microphoneVideoAudio = false }, { $0.backCamera = .mac("0x1") },
                                                   { $0.camerasEnabled = false }, { $0.microphoneEnabled = false }]
        for change in changes {
            var other = config
            change(&other)
            #expect(other.soundtrackCamera == nil)
            #expect(other.videoMicrophonePCMPath == nil)
            #expect(VMMEngine.videoMicrophoneCommand(other) == "microphone mac")
        }
    }

    @Test func sourcesAreSavedAsWords() throws {
        for source in [CameraSource.emulated, .none, .mac("0x1424000005ac8600"), .video("/tmp/test-camera.mp4")] {
            #expect(CameraSource(rawValue: source.rawValue) == source)
            #expect(try JSONDecoder().decode(CameraSource.self, from: JSONEncoder().encode(source)) == source)
        }
        #expect(CameraSource(rawValue: "mac:") == nil && CameraSource(rawValue: "webcam") == nil)
        #expect(CameraSource(rawValue: "video:") == nil)
        #expect(CameraSource.video("/tmp/test-camera.mp4").videoFilePath == "/tmp/test-camera.mp4")
        // A file from before cameras, or with a source this Avo does not know: emulated.
        let old = try JSONDecoder().decode(VMConfig.self, from: Data(#"{"memoryMiB": 4096, "frontCamera": "hologram"}"#.utf8))
        #expect(old.backCamera == .emulated && old.frontCamera == .emulated)
    }

    @Test func androidKeepsItsEmulatedCamerasUntilTheMacFeedsOne() {
        var config = VMConfig()
        #expect(config.cameraFlags.isEmpty, "the image's own emulated cameras")
        config.backCamera = .mac("FaceTime")
        #expect(config.cameraFlags == ["--cameras", "back,front"], "the front one shows a scene drawn on the Mac")
        config.frontCamera = .none
        #expect(config.cameraFlags == ["--cameras", "back"])
        config.backCamera = .none
        #expect(config.cameraFlags == ["--cameras", "none"])
    }

    @Test func whichCamerasAndroidHasNeedsARestartWhatTheyShowDoesNot() {
        let emulated = VMConfig()
        var mac = emulated
        mac.backCamera = .mac("FaceTime")
        #expect(mac.effect(of: emulated) == .restartRequired)
        var other = mac
        other.backCamera = .mac("Continuity")
        #expect(other.effect(of: mac) == .immediate)
        other.frontCamera = .mac("Continuity")
        #expect(other.effect(of: mac) == .immediate, "the front camera was drawn on the Mac already")
        other.frontCamera = .none
        #expect(other.effect(of: mac) == .restartRequired)
        #expect(emulated.effect(of: mac) == .restartRequired, "back to the image's cameras")
    }

    /// Settings › Devices: each of the Mac's devices can be kept from
    /// Android, which then has no such hardware.
    @Test func devicesCanBeKeptFromAndroid() throws {
        let old = try JSONDecoder().decode(VMConfig.self, from: Data(#"{"memoryMiB": 4096}"#.utf8))
        #expect(old.camerasEnabled && old.microphoneEnabled && old.bluetoothEnabled && old.shareClipboard)
        var off = VMConfig()
        off.backCamera = .mac("FaceTime")
        off.camerasEnabled = false
        #expect(off.cameraSources == [.none, .none] && off.cameraFlags == ["--cameras", "none"])
        #expect(off.effect(of: VMConfig()) == .restartRequired)
        var devices = VMConfig()
        devices.microphoneEnabled = false
        devices.shareClipboard = false
        #expect(devices.effect(of: VMConfig()) == .immediate, "the microphone and the clipboard follow at once")
        devices.bluetoothEnabled = false
        #expect(devices.effect(of: VMConfig()) == .restartRequired, "Bluetooth's controller is plugged in at the start")
        let saved = try JSONDecoder().decode(VMConfig.self, from: JSONEncoder().encode(devices))
        #expect(!saved.microphoneEnabled && !saved.shareClipboard && !saved.bluetoothEnabled)
    }

    @Test func avoVMMGetsTheCameras() {
        let paths = AvoPaths(home: URL(filePath: "/Users/u"), temporaryDirectory: URL(filePath: "/tmp/T"))
        var config = VMConfig()
        let image = CuttlefishImage.androidImage(at: URL(filePath: "/img"))
        let plain = VMMEngine.arguments(images: URL(filePath: "/img"),
                                        launch: EngineLaunch(config: config, paths: paths, image: image, bootConfigDisk: URL(filePath: "/c")))
        config.frontCamera = .mac("FaceTime")
        let fed = VMMEngine.arguments(images: URL(filePath: "/img"),
                                      launch: EngineLaunch(config: config, paths: paths, image: image, bootConfigDisk: URL(filePath: "/c")))
        #expect(fed == plain + ["--cameras", "back,front"])
        config.microphoneEnabled = false
        let quiet = VMMEngine.arguments(images: URL(filePath: "/img"),
                                        launch: EngineLaunch(config: config, paths: paths, image: image, bootConfigDisk: URL(filePath: "/c")))
        #expect(quiet == fed + ["--no-microphone"])
    }
}

/// macOS holds Avo.app responsible for the daemon's TCC prompts: a usage
/// string the daemon has and Avo.app lacks gets the daemon killed when it
/// asks (TCC, "must contain an NSCameraUsageDescription key"). Location is
/// not TCC's: CoreLocation asks in the daemon's own name.
@Suite struct PrivacyStringsTests {
    private func plist(_ path: String) throws -> [String: Any] {
        let host = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../../..").standardizedFileURL
        let data = try Data(contentsOf: host.appending(path: path))
        return try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }

    @Test func avoHasEveryUsageStringTheDaemonAsksWith() throws {
        let daemon = try plist("AvoDaemon/Info.plist")
        let avo = try plist("Avo/Info.plist")
        let asked = daemon.keys.filter { $0.hasPrefix("NS") && $0.hasSuffix("UsageDescription") && !$0.hasPrefix("NSLocation") }
        #expect(asked.contains("NSCameraUsageDescription"))
        for key in asked {
            #expect(avo[key] is String, "Avo.app lacks \(key)")
        }
    }
}

@Suite struct GuestCameraTests {
    let build = GuestCamera.builds[0]

    private func patch(at offset: Int) throws -> GuestCamera.Patch {
        try #require(build.patches.first { $0.offset == offset })
    }

    @Test func theFacingComesFromTheCodeInThePadding() throws {
        // `bl 0x64080` in place of `mov w8, #2`.
        let call = try patch(at: 0x2dfa4)
        let word = UInt32(0x9400_0000) | UInt32((0x64080 - 0x2dfa4) >> 2)
        #expect(call.bytes == (0..<4).map { UInt8(truncatingIfNeeded: word >> ($0 * 8)) })
        // The code (clang's bytes for it) ends inside the segment as extended, with `ret`.
        let code = try patch(at: 0x64080)
        #expect(code.bytes.count == 48 && 0x64080 + code.bytes.count <= 0x65000)
        #expect(Array(code.bytes[0..<4]) == [0x88, 0x62, 0x42, 0x39], "ldrb w8, [x20, #0x98]")
        #expect(Array(code.bytes[44..<48]) == [0xc0, 0x03, 0x5f, 0xd6], "ret")
        for offset in [0xd0, 0xd8] {
            #expect(try patch(at: offset).bytes == [0x00, 0xd0, 0x03, 0, 0, 0, 0, 0])
        }
    }

    @Test func theConfigurationIsAvosFile() throws {
        let path = try patch(at: 0x1a0bb)
        // In place of "/vendor/etc/external_camera_config.xml" and its NUL.
        #expect(path.bytes.count == 39)
        #expect(String(decoding: path.bytes.prefix { $0 != 0 }, as: UTF8.self) == GuestCamera.configFile)
        #expect(GuestCamera.config.contains("<CameraIdOffset>-1</CameraIdOffset>"))
        // The HAL stops reading at a Provider without `ignore`.
        #expect(GuestCamera.config.contains("<ignore>"))
        #expect(!GuestCamera.config.contains("'") && !GuestCamera.features.contains("'"), "both go through printf '%s' '…'")
    }

    @Test func onlyTheKnownBuildIsPatched() {
        let path = GuestCamera.library
        #expect(GuestCamera.state(sumOutput: "\(build.sha256)  \(path)\n") == .stock(build))
        #expect(GuestCamera.state(sumOutput: "\(build.patchedSHA256)  \(path)\n") == .patched)
        #expect(GuestCamera.state(sumOutput: "") == .unknown)
    }

    @Test func theScriptChecksTheNodesAndTheCopyBeforeAnythingChanges() throws {
        let lines = GuestCamera.installScript(build).split(separator: "\n").map(String.init)
        #expect(lines.first == "set -e")
        let nodes = lines.indices.filter { lines[$0].contains("/sys/class/video4linux/") }
        let patches = lines.indices.filter { lines[$0].contains("dd of=\(GuestCamera.staged) bs=1 seek=") }
        let check = try #require(lines.firstIndex { $0.contains(build.patchedSHA256) })
        let mount = try #require(lines.firstIndex { $0 == "mount -o bind \(GuestCamera.staged) \(GuestCamera.library)" })
        let restart = try #require(lines.firstIndex { $0 == "setprop ctl.restart \(GuestCamera.provider)" })
        #expect(nodes.count == 2 && nodes.allSatisfy { $0 < patches[0] })
        #expect(patches.count == build.patches.count && patches.allSatisfy { $0 < check })
        #expect(check < mount && mount < restart)
        #expect(lines.last == "setprop ctl.restart cameraserver")
        #expect(GuestCamera.featuresScript.contains("grep -q '^overlay /vendor overlay' /proc/mounts\nremount"))
    }

    /// The patches turn the image's library into the copy the script checks
    /// for (`AVO_CAMERA_LIB`: camera.device-external-impl.so of build 16644040).
    @Test(.enabled(if: ProcessInfo.processInfo.environment["AVO_CAMERA_LIB"] != nil))
    func thePatchesMakeTheKnownCopy() throws {
        var bytes = [UInt8](try Data(contentsOf: URL(filePath: ProcessInfo.processInfo.environment["AVO_CAMERA_LIB"]!)))
        let hex = { (data: [UInt8]) in SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
        #expect(hex(bytes) == build.sha256)
        for patch in build.patches {
            bytes.replaceSubrange(patch.offset..<patch.offset + patch.bytes.count, with: patch.bytes)
        }
        #expect(hex(bytes) == build.patchedSHA256)
    }
}

@Suite(.timeLimit(.minutes(1))) struct CameraFeedTests {
    @Test func eventsSayWhatAndroidStreams() {
        #expect(CameraFeed.parse("camera 0 on 1280 720 30") == .on(camera: 0, .init(width: 1280, height: 720, fps: 30)))
        #expect(CameraFeed.parse("camera 1 off") == .off(camera: 1))
        for line in ["camera 2 off", "camera 0 on 1280 720", "camera 0 on 0 720 30", "cameras 0 off", "sound playback on"] {
            #expect(CameraFeed.parse(line) == nil, "\(line)")
        }
    }

    @Test func framesCarryTheirCameraAndSize() {
        let frame = CameraFeed.frame(camera: 1, request: .init(width: 640, height: 480, fps: 30), jpeg: Data([0xff, 0xd8]))
        #expect(frame == Data([1, 0, 0, 0, 0x80, 2, 0, 0, 0xe0, 1, 0, 0, 2, 0, 0, 0, 0xff, 0xd8]))
    }

    private func size(_ jpeg: Data) -> (Int, Int)? {
        guard let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        return (width, height)
    }

    @Test func picturesAreExactlyTheSizeAndroidStreams() throws {
        for picture in [DrawnCamera.Picture.scene(camera: 0), .scene(camera: 1), .notice(.denied), .notice(.asking), .notice(.missing)] {
            let image = try #require(DrawnCamera.draw(picture, width: 1280, height: 720, time: 3))
            let jpeg = try #require(DrawnCamera.jpeg(image))
            #expect(size(jpeg)! == (1280, 720))
        }
        // A camera's 4:3 picture fills 16:9, cropped, and the other way round.
        let camera = CIImage(color: .red).cropped(to: CGRect(x: 0, y: 0, width: 1920, height: 1440))
        for (width, height) in [(1280, 720), (640, 480), (1920, 1080)] {
            let filled = JPEGEncoder.filling(camera, width: width, height: height)
            #expect(filled.extent == CGRect(x: 0, y: 0, width: width, height: height))
            #expect(size(try #require(JPEGEncoder().jpeg(filled)))! == (width, height))
        }
    }

    /// As a phone's sensor: an upright picture comes a quarter turned
    /// counterclockwise (its top on the left), at the size Android asked
    /// for, and the HAL says the sensor is turned that way.
    @Test func framesComeTurnedAsAPhonesSensor() throws {
        #expect(CameraFeed.sensorOrientation == 90)
        #expect(GuestCamera.config.contains("<Orientation degree=\"\(CameraFeed.sensorOrientation)\"/>"))
        // A portrait picture, red above and blue below.
        let red = CIImage(color: .red).cropped(to: CGRect(x: 0, y: 360, width: 360, height: 360))
        let blue = CIImage(color: .blue).cropped(to: CGRect(x: 0, y: 0, width: 360, height: 360))
        let frame = JPEGEncoder.sensorFrame(red.composited(over: blue), width: 640, height: 480)
        #expect(frame.extent == CGRect(x: 0, y: 0, width: 640, height: 480))
        let jpeg = try #require(JPEGEncoder().jpeg(frame))
        let left = try #require(color(jpeg, x: 0.15, y: 0.5)), right = try #require(color(jpeg, x: 0.85, y: 0.5))
        #expect(left.red > 150 && left.blue < 100, "the picture's top is on the left: \(left)")
        #expect(right.blue > 150 && right.red < 100, "its bottom on the right: \(right)")
        // The drawn scene and notices turn the same way, at the same size.
        let turned = try #require(DrawnCamera.draw(.notice(.missing), width: 640, height: 480, time: 0, turned: true))
        #expect((turned.width, turned.height) == (640, 480))
    }

    /// A wide picture, red on the left and blue on the right, in a square:
    /// filling shows the part its position says, whole it sits on black.
    @Test func videosFillOrFitAsTheirFramingSays() throws {
        let red = CIImage(color: .red).cropped(to: CGRect(x: 0, y: 0, width: 100, height: 100))
        let blue = CIImage(color: .blue).cropped(to: CGRect(x: 100, y: 0, width: 100, height: 100))
        let wide = red.composited(over: blue)
        func colors(_ framing: VideoFraming) throws -> [(red: Int, green: Int, blue: Int)] {
            let placed = JPEGEncoder.placing(wide, width: 100, height: 100, framing: framing)
            #expect(placed.extent == CGRect(x: 0, y: 0, width: 100, height: 100))
            let jpeg = try #require(JPEGEncoder().jpeg(placed))
            return try [(0.1, 0.5), (0.9, 0.5), (0.5, 0.05)].map { try #require(color(jpeg, x: $0.0, y: $0.1)) }
        }
        let isRed = { (c: (red: Int, green: Int, blue: Int)) in c.red > 150 && c.blue < 100 }
        let isBlue = { (c: (red: Int, green: Int, blue: Int)) in c.blue > 150 && c.red < 100 }
        let isBlack = { (c: (red: Int, green: Int, blue: Int)) in c.red < 40 && c.green < 40 && c.blue < 40 }
        let left = try colors(VideoFraming(mode: .fill, position: -1))
        #expect(isRed(left[0]) && isRed(left[1]), "its left edge: \(left)")
        let right = try colors(VideoFraming(mode: .fill, position: 1))
        #expect(isBlue(right[0]) && isBlue(right[1]), "its right edge: \(right)")
        let middle = try colors(VideoFraming())
        #expect(isRed(middle[0]) && isBlue(middle[1]), "its middle: \(middle)")
        let whole = try colors(VideoFraming(mode: .fit))
        #expect(isRed(whole[0]) && isBlue(whole[1]) && isBlack(whole[2]), "all of it, black above: \(whole)")
    }

    /// Phones record portrait movies sideways and say how to turn them.
    @Test func phoneMoviesAreTurnedUpright() {
        #expect(FileVideoCamera.orientation(.identity) == .up)
        #expect(FileVideoCamera.orientation(CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 1080, ty: 0)) == .right)
        #expect(FileVideoCamera.orientation(CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: 1920)) == .left)
        #expect(FileVideoCamera.orientation(CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: 1920, ty: 1080)) == .down)
    }

    /// A movie half red, half blue plays at the size Android asks for, and
    /// starts over at its end: red again after blue.
    @Test func aVideoCameraPlaysItsMovieOverAndOver() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "avo-cam-\(UUID().uuidString.prefix(8)).mov")
        defer { try? FileManager.default.removeItem(at: url) }
        try await Self.writeMovie(url, colors: Array(repeating: (255, 0, 0), count: 5) + Array(repeating: (0, 0, 255), count: 5), fps: 10)
        final class Frames: @unchecked Sendable {
            let lock = NSLock()
            var all: [Data] = []
        }
        let frames = Frames()
        let camera = FileVideoCamera(path: url.path, request: .init(width: 32, height: 24, fps: 20)) { jpeg in
            frames.lock.withLock { frames.all.append(jpeg) }
        }
        camera.start()
        try await Task.sleep(for: .milliseconds(2600))
        camera.stop()
        let jpegs = frames.lock.withLock { frames.all }
        #expect(jpegs.count >= 20)
        #expect(jpegs.allSatisfy { size($0).map { $0 == (32, 24) } ?? false })
        // Each run of one color once: red, blue, red (and maybe more).
        var runs: [String] = []
        for jpeg in jpegs {
            guard let rgb = centerColor(jpeg) else { continue }
            let color = rgb.red > 150 && rgb.blue < 100 ? "red" : rgb.blue > 150 && rgb.red < 100 ? "blue" : "other"
            if color != "other", runs.last != color { runs.append(color) }
        }
        #expect(Array(runs.prefix(3)) == ["red", "blue", "red"], "\(runs)")
    }

    /// One frame of each color, at `fps`, as Motion JPEG (no hardware encoder needed).
    private static func writeMovie(_ url: URL, colors: [(UInt8, UInt8, UInt8)], fps: Int32, width: Int = 64, height: Int = 48) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.jpeg, AVVideoWidthKey: width, AVVideoHeightKey: height,
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
        ])
        writer.add(input)
        #expect(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        for (index, color) in colors.enumerated() {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            var created: CVPixelBuffer?
            CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, nil, &created)
            let pixels = try #require(created)
            CVPixelBufferLockBaseAddress(pixels, [])
            let base = try #require(CVPixelBufferGetBaseAddress(pixels)).assumingMemoryBound(to: UInt8.self)
            let row = CVPixelBufferGetBytesPerRow(pixels)
            for y in 0..<height {
                for x in 0..<width {
                    let pixel = base + y * row + x * 4
                    pixel[0] = color.2
                    pixel[1] = color.1
                    pixel[2] = color.0
                    pixel[3] = 255
                }
            }
            CVPixelBufferUnlockBaseAddress(pixels, [])
            #expect(adaptor.append(pixels, withPresentationTime: CMTime(value: CMTimeValue(index), timescale: fps)))
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(value: CMTimeValue(colors.count), timescale: fps))
        await writer.finishWriting()
        #expect(writer.status == .completed, "\(String(describing: writer.error))")
    }

    /// The color at a picture's middle.
    private func centerColor(_ jpeg: Data) -> (red: Int, green: Int, blue: Int)? {
        color(jpeg, x: 0.5, y: 0.5)
    }

    /// The color at (`x`, `y`) of a picture, as fractions from its top left.
    private func color(_ jpeg: Data, x: Double, y: Double) -> (red: Int, green: Int, blue: Int)? {
        guard let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        var pixel = [UInt8](repeating: 0, count: 4)
        let drawn = pixel.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            // That pixel alone, not the whole picture squeezed into one
            // (the context's y grows upward, the picture's rows downward).
            let (w, h) = (CGFloat(image.width), CGFloat(image.height))
            context.draw(image, in: CGRect(x: -(w * x).rounded(.down), y: -(h * (1 - y)).rounded(.down), width: w, height: h))
            return true
        }
        return drawn ? (Int(pixel[0]), Int(pixel[1]), Int(pixel[2])) : nil
    }

    /// A video camera says when its movie starts over (its soundtrack then
    /// starts over too), and only then: the same request again leaves the
    /// movie playing where it is.
    @Test func aVideoCameraSaysWhenItsMovieStartsOver() {
        final class Starts: @unchecked Sendable {
            let lock = NSLock()
            var cameras: [Int] = []
        }
        let starts = Starts()
        let path = FileManager.default.temporaryDirectory.appending(path: "avo-cam-\(UUID().uuidString.prefix(8)).sock").path
        let feed = CameraFeed(socketPath: path, sources: [.none, .video("/nonexistent/a.mp4")]) { camera in
            starts.lock.withLock { starts.cameras.append(camera) }
        }
        feed.handle("camera 1 on 320 240 15")
        feed.handle("camera 1 on 320 240 15")
        feed.handle("camera 1 on 640 480 30")
        feed.handle("camera 0 on 320 240 15")
        feed.use([.none, .video("/nonexistent/b.mp4")])
        feed.use([.none, .video("/nonexistent/b.mp4")])
        feed.handle("camera 1 off")
        // Runs after everything above on the feed's queue.
        feed.stop()
        #expect(starts.lock.withLock { starts.cameras } == [1, 1, 1])
    }

    /// An emulated camera reaches a fake avo-vmm: the feed's handshake, then
    /// frames of the size asked for, until the stream stops.
    @Test func anEmulatedCameraFeedsItsScene() async throws {
        let path = FileManager.default.temporaryDirectory.appending(path: "avo-cam-\(UUID().uuidString.prefix(8)).sock").path
        defer { unlink(path) }
        let listener = try UnixSocket.listen(path: path)
        defer { Darwin.close(listener) }
        let feed = CameraFeed(socketPath: path, sources: [.none, .emulated])
        defer { feed.stop() }
        feed.handle("camera 1 on 320 240 15")
        let fd = try UnixSocket.accept(listener)
        // Answered at once on this thread, as avo-vmm does: the feed waits
        // 2 s for the answer, less than a busy test run can take to come
        // back to an async read.
        var hello = [UInt8](repeating: 0, count: 12)
        var got = 0
        while got < hello.count {
            let n = hello.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress! + got, $0.count - got) }
            guard n > 0 else { break }
            got += n
        }
        #expect(Data(hello) == Data("camera feed\n".utf8))
        #expect(CameraFeed.writeAll(fd, Data("ok\n".utf8)))
        let stream = FileDescriptorStream(fileDescriptor: fd, label: "fake-avo-vmm")
        defer { stream.close() }
        var reader = StreamReader(stream)
        for _ in 0..<2 {
            let header = try await reader.read(exactly: 16)
            let word = { (i: Int) in Int(header[i * 4]) | Int(header[i * 4 + 1]) << 8 | Int(header[i * 4 + 2]) << 16 | Int(header[i * 4 + 3]) << 24 }
            #expect(word(0) == 1 && word(1) == 320 && word(2) == 240)
            let jpeg = try await reader.read(exactly: word(3))
            #expect(size(jpeg)! == (320, 240))
        }
        // A camera Android does not stream shows nothing.
        feed.handle("camera 0 on 320 240 15")
        feed.handle("camera 1 off")
    }
}
