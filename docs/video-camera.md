# File-backed Android camera (experimental)

This branch adds an MP4/MOV camera source to Avo's existing host-fed virtual camera pipeline. Android applications see the selected file as their front or back camera; no Magisk, LSPosed or Android package patching is required.

## Try it

1. Build the modified Avo app on macOS using [host/README.md](../host/README.md).
2. Start Android. Under **Settings → Devices → Cameras**, enable Cameras.
3. Click **Choose video file…** below either front or back camera and select a local MP4/MOV file.
4. Avo copies the file to its own folder under `~/Library/Application Support/Avo/CameraVideos/`, keeping its name, so the background daemon can access it even when the file picker grants only temporary permissions. The camera menu then lists it under **Videos**, with the other videos imported before, so either camera can show it again without copying it again.
5. If Android was started with both cameras as **Emulated**, restart Android once to switch to the host-fed camera pipeline. If a host-fed camera was already in use, switching sources should take effect without rebooting.
6. Open an Android camera application. The selected video is decoded on macOS, looped and delivered via Avo's pre-existing JPEG camera feed.

## Orientation, as on a phone

Android's cameras are turned as a phone's are: the HAL reports a sensor orientation of 90° (`<Orientation degree="90"/>` in the external camera HAL's configuration), and every source — a video, the Mac's camera and the emulated scene — sends its upright picture turned a quarter counterclockwise (`JPEGEncoder.sensorFrame`). Apps turn it back as they do on a phone, so in a portrait app:

- a portrait video recorded on a phone fills the camera preview instead of being cropped to a landscape band;
- a landscape video shows its middle, as a phone held upright in front of a TV would;
- photos and recordings come out portrait (the HAL writes the turn into their EXIF).

Rotating an Avo window (⌘R) changes the shape of the app's Android display, but Android does not see a turned phone: its displays keep rotation 0 and the accelerometer stays upright. In a landscape window the picture therefore stays upright and is cropped to the window's shape, and photos still come out portrait. Turning the phone itself for Android (display rotation and accelerometer following the window) would need Avo's displays to rotate rather than resize; that is not part of this change.

This applies to the Mac's camera and the emulated scene too, not only to videos, and to every app the next time Android starts (the HAL reads its configuration at boot).

## Framing a video

Below a camera that shows a video, **Fill the picture**, **Whole video** and **Stretch** choose how the video meets Android's picture, for that video only (`VMConfig.cameraVideoFraming`, by its path):

- **Fill the picture** (the default) covers the picture and crops the video; the slider picks which part shows — its left (or top) edge, its middle, or its right (or bottom) edge. A landscape video in a portrait app shows only a slice of its width, so this is where to aim it.
- **Whole video** shows all of it, with black where it does not reach the picture's edges.
- **Stretch** shows all of the video stretched to the picture's shape, with no black and no cropping; its proportions change to fit.
- **0° / 90° / 180° / 270°** turns the video clockwise first, for one recorded on its side (or one you want on its side). It applies to every framing.
- The **zoom** slider (50–300%) scales the video from the size its framing gives: above 100% it comes closer and is cropped (the position slider then picks the part, along the side cropped most), below 100% it goes away with black around it. Zooming into a large movie decodes it bigger from that moment, so the picture stays sharp.

A change shows in Android at the next frame, without restarting the video; the slider writes when it is let go. Apps mirror the front camera's preview, so there the slider's left shows on the right.

## Video soundtrack as microphone

After choosing a video, Avo also decodes its audio (if any) to an immutable `.pcm` sidecar in the same folder. In **Settings → Devices → Microphone**, turn on **Use a camera video’s sound** to send this audio into Android's virtual mic instead of asking macOS for live microphone access. Turn it off to keep using the Mac's microphone. The front camera movie is preferred when both front and back have video sources. The switch is unavailable until a camera shows a video. Audio is optional: a file without a usable soundtrack still provides a camera image, but when video-mic mode is selected the guest will record silence, and the note under the switch says so.

The PCM file is 48 kHz, stereo, signed 16-bit little endian. It follows the movie's timeline and is exactly as long as the movie: a soundtrack that starts late is preceded by silence, one that ends early is followed by silence, and audio past the movie's end is dropped. Sound and picture therefore loop at the same length and do not drift apart from one loop to the next. Videos imported before this layout keep their old sidecar; choose them again to rebuild it. The VM maps it read-only and loops playback while Android captures microphone audio, converting to the app's requested rate (8–48 kHz) and mono/stereo configuration. Below 48 kHz the soundtrack goes through a windowed-sinc low-pass first, so 8/16 kHz calls do not hear the movie's high frequencies folded back as hiss. Microphone source changes take effect on **the next capture session**; close and reopen an Android call/recorder after changing sources. Audio from the Mac microphone is never mixed into the file-backed mode.

Video FPS follows the Android camera stream request. The movie is decoded in order, as a player does; when its frame rate is lower than the camera's, the last frame is sent again, and a slow tick decodes the frames it missed without sending them so the picture never falls behind. At present, pause/resume is not exposed. Audio and video run on their respective Android capture clocks and may start at slightly different times; exact A/V lip-sync is not guaranteed yet.

## Known limitations

- This is a first implementation. It has **not been built or exercised on a macOS machine yet**; compatibility needs validation.
- Video selection is intentionally handled by the Avo macOS Control Panel. The user confirmed that an Android-side file picker is unnecessary.
- Each import makes a new copy. Avo keeps the copies a camera shows and the five newest others; older ones are deleted at the next import. **Remove video** (beside Choose video file…) deletes any of them now, or all that no camera shows; a camera showing the removed video goes back to Emulated, and the other camera's video cannot be removed from this camera's menu.
- Source is saved as an absolute path; if files are moved or deleted, Avo cannot decode them.
- Invalid video files will result in the VM's ordinary gray/no-frame fallback. An unsupported or missing audio track yields silence in video-mic mode.
- When both cameras use a default emulated AOSP pipeline, selecting the file after Android starts needs a restart. This follows the existing camera configuration design.

## Implementation

- `CameraSource.video(path)` stores the video source in VM configuration; `VMConfig.soundtrackCamera` and `videoMicrophonePCMPath` choose whose soundtrack the microphone hears.
- `VideoFraming` (fill with a position, or fit) is read by a playing `FileVideoCamera` at every frame through `CameraFeed.useFraming`; `JPEGEncoder.placing` draws it.
- `CameraFeed.sensorOrientation` and `JPEGEncoder.sensorFrame` turn every source's picture as a phone's sensor would; `GuestCamera.config` declares the same orientation to the HAL.
- `FileVideoCamera` decodes the movie sequentially with `AVAssetReader` on a dispatch timer. It sends the frame due at the elapsed time, starts a new reader at the asset duration and encodes/crops into the requested JPEG frame size, turning phone videos upright from the track's preferred transform.
- `CameraFeed` connects the new producer to the existing virtio-media / Android HAL path.
- avo-vmm rewrites every frame as a plain baseline JPEG before Android gets it (`jpeg.rs`, lossless: the same quantized coefficients, written again without restart intervals or APP segments, with the standard Huffman tables). The Mac's encoders write a restart marker after every row of blocks; Android's external camera HAL rejected about half of a movie's frames as malformed ("Convert V4L2 frame to YU12 failed! res 1" in `android warnings:`), and apps recorded 18–20 frames a second. `camerastats` counts frames that could not be rewritten (`not-rewritten`), which go as they came.
- Frame rate can be followed with `log stream --predicate 'category == "cameras"' --info`: `camera video:` lines say what the Mac sent and what decoding and encoding took; `camerastats` lines (avo-vmm's virtio-media device) say how many frames Android took, how many found no buffer queued, and how many were repeats, then what the JPEGs taken were: in how many buffers, their size and chroma sampling (`1920x1080 sof0 h2v2,h1v1,h1v1`, with `dri`/`app` segments and `no-eoi`), and how many a second were over 64, 128, 256 and 512 KiB. Frames go to Android on the stream's own clock, as from a sensor: every 1/fps the newest frame (or, with none new, the last again) fills the buffer Android has queued, so a recorder sees evenly spaced frames; a new frame that finds no buffer waits for the next tick, unless a newer one replaces it. While a camera streams, `android streams:` lines (every 5 s, from `dumpsys media.camera`) give the frames a second the camera HAL produced for each of the app's streams — its preview and, while recording, the encoder's — so a slow step inside Android shows up as a stream below what `camerastats` says Android took. Next to them, `busiest threads:` lines (toybox `top -H`) name the Android threads using the most CPU at that moment: the camera HAL, an app's render thread, the video encoder. And `android warnings:` lines gather Android's own warnings and errors since the last look (logcat, W and up), each kind once with how often it came: a frame the camera HAL could not read, or one a recorder dropped, shows up there even where every count above calls it delivered.
- `VideoAudioExtractor` decodes local MP4 audio into a PCM sidecar; `virtio/sound.rs` feeds it into Android capture without Core Audio permissions.
- `CameraVideos` copies the chosen file to a stable user-local location, builds the sidecar off the main actor, lists the imported videos and prunes old ones.

## Verification to do on macOS

- `cd host/AvoKit && swift test --filter CameraSettingsTests`
- `cd host/AvoKit && swift test --filter CameraFeedTests`
- `cargo test --manifest-path engine/hvf/Cargo.toml -p avo-vmm virtio::sound::` and `control::tests::microphone`
- `make build` (it applies `scripts/avo-kit-patches` to `vendor/avo_kit` first)
- In Android, test both camera facings using a Camera2 app, repeat past EOF, switch back to emulated, and verify normal Mac webcam behavior.
- In a portrait app: a portrait phone video fills the preview upright, a taken photo opens upright in Photos; in a landscape window the preview stays upright. Check a CameraX app and a legacy Camera API app (both honour the sensor orientation).
