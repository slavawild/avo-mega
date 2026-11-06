# Camera2 diagnostics (Avo vs a real Android phone)

The `scripts/camera-diagnostics.sh` utility collects **read-only** CameraService
information to investigate differences between Avo's host-fed (Mac / movie / picture)
camera and a physical Android camera. It does not modify the camera HAL, fabricate
metadata, or change the image/video stream.

This is especially useful when AnonChat briefly shows a "taken with camera" badge
while a photo or video is being prepared, but removes it after the upload completes.
That symptom alone does **not** prove whether the application, media processing,
or its server made the final decision.

## Requirements

- macOS (for Avo) or another computer with `bash` and Android SDK Platform-Tools (`adb`).
- A running Avo Android guest and, for comparison, a real Android phone with USB debugging.
- AnonChat installed on the Android device you are currently testing.
- Do not capture or share private media purely for testing.

Enable ADB for the Avo instance in Avo Settings. Alternatively, in a setup with
`avoctl` available:

```sh
avoctl config adbEnabled=true
adb connect 127.0.0.1:5555
adb devices -l
```

If Avo and the phone are attached at the same time, pass `--serial` for each
device (the serial is the first column of `adb devices -l`).

## 1. Collect Avo's report

In the repository checkout:

```sh
bash scripts/camera-diagnostics.sh collect --label avo --serial 127.0.0.1:5555
```

While the script waits:

1. Open AnonChat on the Avo guest.
2. Take a new photo using the app's camera, send it, and observe whether the badge
   remains after upload.
3. Record a video using the app's camera, send it, and observe the badge after upload.
4. Only after both uploads finish, return to Terminal and press Enter.

The script prints its output directory (under `build/camera-diagnostics/`).

You can repeat with the Avo camera using a **Mac webcam** instead of a file-backed
source. This is a very useful control: both use the same guest external Camera HAL.

## 2. Collect the physical phone's report

```sh
adb devices -l
bash scripts/camera-diagnostics.sh collect --label phone --serial YOUR_PHONE_ADB_SERIAL
```

Perform the **same two operations** in AnonChat on the phone and press Enter.

## 3. Compare the reports

```sh
bash scripts/camera-diagnostics.sh compare \
  build/camera-diagnostics/avo-TIMESTAMP.SUFFIX \
  build/camera-diagnostics/phone-TIMESTAMP.SUFFIX
```

Compare `characteristics-focus.txt` first, then the full `camera-before.txt`
for every camera ID. Key fields to pay attention to:

- `android.info.supportedHardwareLevel` (EXTERNAL / LEGACY / LIMITED / FULL / LEVEL_3)
- `android.lens.facing`, `android.sensor.orientation`
- `android.request.availableCapabilities`
- Sensor size, focal length, flash availability and stream configuration
- Actual capture request/results in `camera-watch.txt` and `camera-3a.txt`
- Camera HAL and media errors in `logcat-after.txt`

The same numeric camera ID can refer to different sensors on different devices.
Do not directly diff metadata without identifying the front/back camera in each
report. Also, Android versions can format `dumpsys media.camera` differently.

On Android 13 or later, `cmd media.camera watch` can monitor selected request
and result tags while AnonChat is recording. The script saves these if supported.
A failed or unsupported watch command does **not** prevent the other diagnostics
from being collected.

## Interpretation

| Result | Likely direction to investigate |
| --- | --- |
| Badge disappears for Avo's MP4, picture, **and** Mac webcam | Shared external Camera HAL or app/server processing |
| Badge disappears only for file-backed sources | Frame generation, timestamp, encoding, or supplied media characteristics |
| Camera2 characteristics differ but both badges remain | Difference is not sufficient by itself |
| Photo/video works, but badge changes only after upload | Examine the app's post-upload message update and the resulting media; HAL metadata alone does not prove the cause |

A virtual camera's advertised `LENS_FACING` is not enough to turn it into a
full built-in camera. **Do not randomize characteristics or declare unimplemented
capabilities**: Android applications and the camera framework expect a coherent
set of keys and actual camera behavior.

## Optional media inspection

If AnonChat allows you to export both the local captured file and the uploaded
file, compare them using ordinary tools. These tools are **not** installed by
this diagnostic utility:

```sh
exiftool -G1 -a -s local-photo.jpg exported-photo.jpg
ffprobe -hide_banner -show_streams -show_format recorded-video.mp4
```

It is normal for sharing services to remove EXIF metadata or transcode videos;
that does not prove that the application uses those fields for its badge.

## Privacy and limitations

**Review and redact the reports before sharing them.** `logcat-after.txt` may
include application messages, while `device.txt` includes the Android build
fingerprint. The script does not extract any AnonChat private database or
network traffic; it cannot establish server-side badge rules. It also leaves
the camera configuration unchanged. The global camera tag watch is stopped
when collection finishes.
