# File-backed Android camera (experimental)

This branch adds an MP4/MOV camera source to Avo's existing host-fed virtual camera pipeline. Android applications see the selected file as their front or back camera; no Magisk, LSPosed or Android package patching is required.

## Try it

1. Build the modified Avo app on macOS using [host/README.md](../host/README.md).
2. Start Android. Under **Settings → Devices → Cameras**, enable Cameras.
3. Click **Choose video file…** below either front or back camera and select a local MP4/MOV file.
4. Avo copies the file to its own folder under `~/Library/Application Support/Avo/CameraVideos/`, keeping its name, so the background daemon can access it even when the file picker grants only temporary permissions. The camera menu then lists it under **Videos**, with the other videos imported before, so either camera can show it again without copying it again.
5. If Android was started with both cameras as **Emulated**, restart Android once to switch to the host-fed camera pipeline. If a host-fed camera was already in use, switching sources should take effect without rebooting.
6. Open an Android camera application. The selected video is decoded on macOS, looped and delivered via Avo's pre-existing JPEG camera feed.

## Video soundtrack as microphone

After choosing a video, Avo also decodes its audio (if any) to an immutable `.pcm` sidecar in the same folder. In **Settings → Devices → Microphone**, turn on **Use a camera video’s sound** to send this audio into Android's virtual mic instead of asking macOS for live microphone access. Turn it off to keep using the Mac's microphone. The front camera movie is preferred when both front and back have video sources. The switch is unavailable until a camera shows a video. Audio is optional: a file without a usable soundtrack still provides a camera image, but when video-mic mode is selected the guest will record silence, and the note under the switch says so.

The PCM file is 48 kHz, stereo, signed 16-bit little endian. It follows the movie's timeline and is exactly as long as the movie: a soundtrack that starts late is preceded by silence, one that ends early is followed by silence, and audio past the movie's end is dropped. Sound and picture therefore loop at the same length and do not drift apart from one loop to the next. Videos imported before this layout keep their old sidecar; choose them again to rebuild it. The VM maps it read-only and loops playback while Android captures microphone audio, converting to the app's requested rate (8–48 kHz) and mono/stereo configuration. Below 48 kHz the soundtrack goes through a windowed-sinc low-pass first, so 8/16 kHz calls do not hear the movie's high frequencies folded back as hiss. Microphone source changes take effect on **the next capture session**; close and reopen an Android call/recorder after changing sources. Audio from the Mac microphone is never mixed into the file-backed mode.

Video FPS follows the Android camera stream request. The movie is decoded in order, as a player does; when its frame rate is lower than the camera's, the last frame is sent again, and a slow tick decodes the frames it missed without sending them so the picture never falls behind. At present, pause/resume is not exposed. Audio and video run on their respective Android capture clocks and may start at slightly different times; exact A/V lip-sync is not guaranteed yet.

## Known limitations

- This is a first implementation. It has **not been built or exercised on a macOS machine yet**; compatibility needs validation.
- Video selection is intentionally handled by the Avo macOS Control Panel. The user confirmed that an Android-side file picker is unnecessary.
- Each import makes a new copy. Avo keeps the copies a camera shows and the five newest others; older ones are deleted at the next import.
- Source is saved as an absolute path; if files are moved or deleted, Avo cannot decode them.
- Invalid video files will result in the VM's ordinary gray/no-frame fallback. An unsupported or missing audio track yields silence in video-mic mode.
- When both cameras use a default emulated AOSP pipeline, selecting the file after Android starts needs a restart. This follows the existing camera configuration design.

## Implementation

- `CameraSource.video(path)` stores the video source in VM configuration; `VMConfig.soundtrackCamera` and `videoMicrophonePCMPath` choose whose soundtrack the microphone hears.
- `FileVideoCamera` decodes the movie sequentially with `AVAssetReader` on a dispatch timer. It sends the frame due at the elapsed time, starts a new reader at the asset duration and encodes/crops into the requested JPEG frame size, turning phone videos upright from the track's preferred transform.
- `CameraFeed` connects the new producer to the existing virtio-media / Android HAL path.
- `VideoAudioExtractor` decodes local MP4 audio into a PCM sidecar; `virtio/sound.rs` feeds it into Android capture without Core Audio permissions.
- `CameraVideos` copies the chosen file to a stable user-local location, builds the sidecar off the main actor, lists the imported videos and prunes old ones.

## Verification to do on macOS

- `cd host/AvoKit && swift test --filter CameraSettingsTests`
- `cd host/AvoKit && swift test --filter CameraFeedTests`
- `cargo test --manifest-path engine/hvf/Cargo.toml -p avo-vmm virtio::sound::` and `control::tests::microphone`
- `make build` (it applies `scripts/avo-kit-patches` to `vendor/avo_kit` first)
- In Android, test both camera facings using a Camera2 app, repeat past EOF, switch back to emulated, and verify normal Mac webcam behavior.
