import Foundation

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
    /// A local MP4/MOV copied into Avo's Application Support folder.
    /// The daemon decodes it only while Android streams the camera.
    case video(String)
    /// None: Android does not have this camera.
    case none

    public var videoFilePath: String? {
        if case .video(let path) = self { return path }
        return nil
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
    /// to a video's soundtrack, the front camera's video first (calls use
    /// it), else the back one's. Nil otherwise: the Mac's microphone, or
    /// silence with the microphone off.
    public var soundtrackCamera: Int? {
        guard microphoneEnabled, microphoneVideoAudio else { return nil }
        let sources = cameraSources
        return [1, 0].first { sources[$0].videoFilePath != nil }
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
