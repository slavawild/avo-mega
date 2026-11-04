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
    /// The front video is preferred because it is commonly used for video calls.
    /// A sidecar is made when the movie is imported by the Control Panel.
    public var videoMicrophonePCMPath: String? {
        guard microphoneVideoAudio, camerasEnabled else { return nil }
        for source in [frontCamera, backCamera] {
            if let path = source.videoFilePath {
                return URL(fileURLWithPath: path).deletingPathExtension().appendingPathExtension("pcm").path
            }
        }
        return nil
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
