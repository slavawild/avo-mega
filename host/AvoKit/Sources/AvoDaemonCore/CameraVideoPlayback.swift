import AvoKit
import Foundation

// MARK: - A camera's movie (Settings › Devices › Cameras)

/// An engine whose cameras can show a movie (VMMEngine: CameraFeed's
/// FileVideoCamera), which says where it is and moves it.
protocol CameraVideoEngine: VMEngine {
    func cameraVideoPlayback(camera: Int, seekTo seconds: Double?) async -> CameraVideoPlayback?
}

extension DaemonCore {
    /// Where camera `request.camera`'s movie is (0 back, 1 front), after
    /// moving it to `request.seconds` into it when given; nil when the
    /// camera shows no movie or Android is not running. For the Control
    /// Panel's Settings › Devices › Cameras.
    public func cameraVideoPlayback(_ request: CameraVideoSeek, client: ClientID) async throws -> CameraVideoPlayback? {
        guard role(of: client) == .controlPanel else { throw AvoError.unauthorizedCaller }
        guard (0..<2).contains(request.camera) else { return nil }
        guard let engine = deps.engine as? any CameraVideoEngine else { return nil }
        return await engine.cameraVideoPlayback(camera: request.camera, seekTo: request.seconds)
    }
}
