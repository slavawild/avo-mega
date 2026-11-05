import Foundation
import UniformTypeIdentifiers

/// What one of Android's cameras shows (Settings › Devices › Cameras).
///
/// While both cameras are emulated, Android has the image's own emulated
/// back and front cameras. Any other choice gives it cameras the daemon feeds
/// (avo-vmm `--cameras`, camera.rs; CameraFeed): one of this Mac's cameras,
/// or, for an emulated one, a scene the daemon draws. Which cameras Android
/// has is set when it starts; what each one shows changes at once.
public enum CameraSource: Hashable, Sendable {
    /// A scene drawn for it.
    case emulated
    /// One of this Mac's cameras (`AVCaptureDevice.uniqueID`).
    case mac(String)
    /// A local movie (MP4, MOV) or picture (JPEG, PNG, HEIC…) copied into
    /// Avo's Application Support folder (`isPicture` tells which). The
    /// daemon decodes it only while Android streams the camera: a movie
    /// plays over and over, a picture stays.
    case video(String)
    /// None: Android does not have this camera.
    case none

    public var videoFilePath: String? {
        if case .video(let path) = self { return path }
        return nil
    }

    /// Whether an imported file is a picture (shown still, without sound)
    /// rather than a movie, by its kind.
    public static func isPicture(_ path: String) -> Bool {
        let type = UTType(filenameExtension: URL(fileURLWithPath: path).pathExtension)
        return type?.conforms(to: .image) == true && type?.conforms(to: .movie) != true
    }

    /// An imported movie (not a picture) this camera shows.
    public var movieFilePath: String? {
        videoFilePath.flatMap { Self.isPicture($0) ? nil : $0 }
    }

    /// The 48 kHz stereo S16LE sidecar beside an imported video: its
    /// soundtrack for Android's microphone.
    public static func soundtrackPath(ofVideo path: String) -> String {
        URL(fileURLWithPath: path).deletingPathExtension().appendingPathExtension("pcm").path
    }

    public var macCameraID: String? {
        if case .mac(let id) = self { return id }
        return nil
    }
}

/// How a camera's video fills the picture (Settings › Devices › Cameras):
/// all of it, cropped where `position` says; the whole video with black
/// around it; or stretched to it. Turned `rotation` quarters clockwise
/// first, and `zoom` times the size its mode gives. Kept per video
/// (`VMConfig.cameraVideoFraming`).
public struct VideoFraming: Codable, Hashable, Sendable {
    public enum Mode: String, Codable, Hashable, Sendable {
        /// The picture full, the video cropped to it.
        case fill
        /// The whole video, with black where it does not reach.
        case fit
        /// The whole video stretched to the picture's shape (its own
        /// proportions are not kept).
        case stretch
    }

    /// How far `zoom` goes (0.5 shows the video at half the size its mode
    /// gives, 3 at three times).
    public static let zoomRange: ClosedRange<Double> = 0.5...3

    public var mode: Mode
    /// Filling, which part of the video shows along the side it is cropped
    /// on: -1 its left (or top) edge, 0 its middle, 1 its right (or bottom).
    public var position: Double
    /// Quarter turns clockwise of the upright video (0 to 3), for one that
    /// was recorded on its side or should be.
    public var rotation: Int
    /// Times the size `mode` gives: above 1 the video comes closer (and is
    /// cropped, `position` choosing the part), below 1 it goes away (black
    /// around it).
    public var zoom: Double

    public init(mode: Mode = .fill, position: Double = 0, rotation: Int = 0, zoom: Double = 1) {
        self.mode = mode
        self.position = position
        self.rotation = rotation
        self.zoom = zoom
    }

    private enum CodingKeys: String, CodingKey { case mode, position, rotation, zoom }

    /// Framing saved before rotation and zoom existed has neither.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        mode = try container.decode(Mode.self, forKey: .mode)
        position = try container.decode(Double.self, forKey: .position)
        rotation = try container.decodeIfPresent(Int.self, forKey: .rotation) ?? 0
        zoom = try container.decodeIfPresent(Double.self, forKey: .zoom) ?? 1
    }

    /// `zoom` within `zoomRange`.
    public var clampedZoom: Double {
        min(max(zoom.isFinite ? zoom : 1, Self.zoomRange.lowerBound), Self.zoomRange.upperBound)
    }

    /// Whether some of the video is cropped, so `position` has a part to choose.
    public var crops: Bool { mode == .fill || clampedZoom > 1 }

    /// `rotation` as 0, 1, 2 or 3 quarter turns clockwise.
    public var quarterTurns: Int { ((rotation % 4) + 4) % 4 }

    /// `position` within -1…1.
    public var clampedPosition: Double { min(max(position.isFinite ? position : 0, -1), 1) }
}

extension CameraSource: Codable {
    /// `emulated`, `none`, `mac:<unique ID>`, or `video:<absolute path>`.
    public var rawValue: String {
        switch self {
        case .emulated: "emulated"
        case .none: "none"
        case .mac(let id): "mac:" + id
        case .video(let path): "video:" + path
        }
    }

    public init?(rawValue: String) {
        switch rawValue {
        case "emulated": self = .emulated
        case "none": self = .none
        case let value where value.hasPrefix("mac:") && value.count > 4: self = .mac(String(value.dropFirst(4)))
        case let value where value.hasPrefix("video:/") && value.count > 7: self = .video(String(value.dropFirst(6)))
        default: return nil
        }
    }

    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let source = CameraSource(rawValue: raw) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "unknown camera source \(raw)"))
        }
        self = source
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

extension VMConfig {
    /// The camera (as avo-vmm numbers them: 0 back, 1 front) whose video's
    /// soundtrack Android's microphone hears: with the microphone on and set
    /// to a video's soundtrack, the front camera's movie first (calls use
    /// it), else the back one's; a picture has no sound. Nil otherwise: the
    /// Mac's microphone, or silence with the microphone off.
    public var soundtrackCamera: Int? {
        guard microphoneEnabled, microphoneVideoAudio else { return nil }
        let sources = cameraSources
        return [1, 0].first { sources[$0].movieFilePath != nil }
    }

    /// `soundtrackCamera`'s video's soundtrack sidecar (made when the Control
    /// Panel imports the video; missing when the video has no sound).
    public var videoMicrophonePCMPath: String? {
        soundtrackCamera.flatMap { cameraSources[$0].videoFilePath }.map(CameraSource.soundtrackPath(ofVideo:))
    }

    /// The back camera first, as avo-vmm numbers them (0 back, 1 front);
    /// none while cameras are off.
    public var cameraSources: [CameraSource] { camerasEnabled ? [backCamera, frontCamera] : [.none, .none] }

    /// avo-vmm's `--cameras`: none while both cameras are the image's
    /// emulated ones, else the cameras Android has.
    public var cameraFlags: [String] {
        let sources = cameraSources
        if sources == [.emulated, .emulated] { return [] }
        let present = zip(["back", "front"], sources).filter { $0.1 != .none }.map(\.0)
        return ["--cameras", present.isEmpty ? "none" : present.joined(separator: ",")]
    }
}

/// Where the movie a camera shows has got to (Settings › Devices ›
/// Cameras, DaemonClient.cameraVideoPlayback): `position` seconds into
/// its `duration`, and whether it is `paused` there. Not `playing` while
/// no Android app uses the camera: `position` is then where it starts the
/// next time (and `paused`, whether it waits there).
public struct CameraVideoPlayback: Codable, Hashable, Sendable {
    public var playing: Bool
    public var position: Double
    /// Nil until the movie has loaded (only while it plays).
    public var duration: Double?
    public var paused: Bool

    public init(playing: Bool, position: Double, duration: Double?, paused: Bool = false) {
        self.playing = playing
        self.position = position
        self.duration = duration
        self.paused = paused
    }
}

/// A request for `CameraVideoPlayback`: camera 0 (back) or 1 (front), the
/// second of its movie to go to, and whether to pause or play it; nil
/// for either leaves it as it is.
public struct CameraVideoSeek: Codable, Hashable, Sendable {
    public var camera: Int
    public var seconds: Double?
    public var paused: Bool?

    public init(camera: Int, seconds: Double?, paused: Bool? = nil) {
        self.camera = camera
        self.seconds = seconds
        self.paused = paused
    }
}
