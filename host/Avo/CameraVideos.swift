import AvoKit
import Foundation

/// The movies Settings › Devices › Cameras can show as a camera
/// (CameraSource.video): copies in Application Support/Avo/CameraVideos,
/// each in a folder of its own under the name it had on the Mac, beside its
/// soundtrack sidecar (VideoAudioExtractor). The daemon reads them there for
/// good; the file panel's grant to the original passes.
///
/// The menu lists them all, so a movie can be chosen again without copying
/// it again. Past the `kept` newest, those no camera shows go at the next
/// import.
enum CameraVideos {
    /// One imported movie.
    struct Movie: Hashable, Sendable {
        let path: String
        let added: Date

        /// The name it had on the Mac (copies from before folders of their
        /// own carry a UUID instead).
        var name: String { URL(fileURLWithPath: path).lastPathComponent }
    }

    /// Movies kept besides the ones a camera shows.
    static let kept = 5
    /// What lies beside a movie: its soundtrack sidecar, and one being made.
    static let sidecarExtensions: Set<String> = ["pcm", "pcm-part"]

    /// A movie, not a sidecar: whatever kind the file panel let through.
    static func isMovie(_ url: URL) -> Bool {
        !sidecarExtensions.contains(url.pathExtension.lowercased())
    }

    static var folder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Avo/CameraVideos", directoryHint: .isDirectory)
    }

    /// Copies a movie the user chose into `folder` and makes its soundtrack
    /// sidecar, then lets go of old copies no camera shows (`inUse`: the
    /// paths the cameras show now). Returns the copy's path, and a note for
    /// the user when its sound cannot be the microphone (the camera works
    /// anyway). Copying a long movie takes a while: run it off the main actor.
    static func importMovie(_ url: URL, inUse: Set<String>) async throws -> (path: String, note: String?) {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        let home = folder.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        // avo-vmm takes the sidecar's path on one line of its control socket.
        let name = url.lastPathComponent.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
        let destination = home.appending(path: name)
        do {
            try FileManager.default.copyItem(at: url, to: destination)
        } catch {
            try? FileManager.default.removeItem(at: home)
            throw error
        }
        prune(keeping: inUse.union([destination.path]))
        do {
            let sound = try await VideoAudioExtractor.createSidecar(for: destination)
            return (destination.path, sound ? nil : String(localized: "This video has no sound Avo can play, so its camera shows it without any."))
        } catch {
            return (destination.path, error.localizedDescription)
        }
    }

    /// The movies in `folder`, newest first.
    static func imported() -> [Movie] {
        let manager = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .creationDateKey]
        guard let entries = try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys, options: .skipsHiddenFiles) else { return [] }
        var movies: [Movie] = []
        for entry in entries {
            let values = try? entry.resourceValues(forKeys: Set(keys))
            let added = values?.creationDate ?? .distantPast
            if values?.isDirectory == true {
                let inside = (try? manager.contentsOfDirectory(at: entry, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
                if let movie = inside.first(where: isMovie) {
                    movies.append(Movie(path: movie.path, added: added))
                }
            } else if isMovie(entry) {
                // A copy from before folders of their own.
                movies.append(Movie(path: entry.path, added: added))
            }
        }
        return movies.sorted { $0.added > $1.added }
    }

    /// Removes the movies (and their sidecars) past the `kept` newest that
    /// are not in `inUse`. One the engine still plays goes on playing: its
    /// open file outlives the name.
    static func prune(keeping inUse: Set<String>) {
        let unused = imported().filter { !inUse.contains($0.path) }
        for movie in unused.dropFirst(kept) { remove(movie) }
    }

    private static func remove(_ movie: Movie) {
        let url = URL(fileURLWithPath: movie.path)
        let parent = url.deletingLastPathComponent()
        if parent.standardizedFileURL == folder.standardizedFileURL {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(atPath: CameraSource.soundtrackPath(ofVideo: movie.path))
        } else {
            try? FileManager.default.removeItem(at: parent)
        }
    }
}
