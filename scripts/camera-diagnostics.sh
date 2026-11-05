#!/usr/bin/env bash
# Capture Android Camera2/HAL diagnostics without changing camera behavior.
# Run once against Avo and once against a real phone, then compare.
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  scripts/camera-diagnostics.sh collect [--serial ADB_SERIAL] [--label avo|phone] [--out DIRECTORY]
  scripts/camera-diagnostics.sh compare AVO_REPORT_DIR PHONE_REPORT_DIR

Requires Android platform-tools (adb). On Avo, enable ADB in its settings
(or: avoctl config adbEnabled=true) and run: adb connect 127.0.0.1:5555

The collect command prompts you to capture/upload photo and video in AnonChat,
then saves CameraService dumps, camera characteristics, request/result tags and
recent logcat output. It never changes camera characteristics.
USAGE
}

mode="collect"
if [ "$#" -gt 0 ]; then
  case "$1" in
    collect|compare) mode="$1"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown mode: $1" >&2; usage >&2; exit 2 ;;
  esac
fi

focus_regex='android\.(info\.supportedHardwareLevel|lens\.facing|sensor\.orientation|sensor\.info\.physicalSize|lens\.info\.availableFocalLengths|request\.availableCapabilities|scaler\.availableStreamConfigurations|scaler\.streamConfigurationMap|flash\.info\.available|jpeg\.availableThumbnailSizes)|Camera ID|Camera Id|Device [0-9]+|Number of camera'

if [ "$mode" = compare ]; then
  if [ "$#" -ne 2 ]; then usage >&2; exit 2; fi
  left="$1"
  right="$2"
  for path in "$left" "$right"; do
    if [ ! -f "$path/characteristics-focus.txt" ]; then
      echo "Missing report: $path/characteristics-focus.txt" >&2
      exit 1
    fi
  done
  echo "Focused camera characteristics (Avo vs phone):"
  diff -u --label "Avo: $left" --label "Phone: $right" \
    "$left/characteristics-focus.txt" "$right/characteristics-focus.txt" || true
  echo
  echo "Full CameraService dumps:"
  printf '  %s\n  %s\n' "$left/camera-before.txt" "$right/camera-before.txt"
  echo "Note: camera IDs/order can differ, and dumpsys output varies by Android version."
  exit 0
fi

serial=""
label="avo"
out_root="build/camera-diagnostics"
while [ "$#" -gt 0 ]; do
  case "$1" in
    --serial|--label|--out)
      if [ "$#" -lt 2 ]; then echo "Missing value after $1" >&2; exit 2; fi
      case "$1" in
        --serial) serial="$2" ;;
        --label) label="$2" ;;
        --out) out_root="$2" ;;
      esac
      shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

case "$label" in
  ""|*[!A-Za-z0-9._-]*) echo "Label must use only letters, digits, . _ -" >&2; exit 2 ;;
esac

adb_bin="${ADB:-adb}"
if ! command -v "$adb_bin" >/dev/null 2>&1; then
  echo "adb not found. Install Android platform-tools or set ADB=/path/to/adb" >&2
  exit 1
fi

adb_args=("$adb_bin")
if [ -n "$serial" ]; then adb_args+=(-s "$serial"); fi
adb_do() { "${adb_args[@]}" "$@"; }

if ! adb_do get-state >/dev/null 2>&1; then
  echo "No authorized ADB device (or multiple devices without --serial)." >&2
  adb devices -l || true
  echo "For Avo: enable ADB and run 'adb connect 127.0.0.1:5555'." >&2
  exit 1
fi

mkdir -p "$out_root"
out="$(mktemp -d "$out_root/$label-$(date +%Y%m%d-%H%M%S).XXXXXX")"
echo "Collecting diagnostics in $out"

capture() {
  name="$1"; shift
  if ! adb_do "$@" >"$out/$name" 2>&1; then
    printf 'Command failed: %s\n' "$name" >>"$out/errors.txt"
  fi
}

{
  printf 'Report label: %s\n' "$label"
  date -u '+Collected (UTC): %Y-%m-%dT%H:%M:%SZ'
  for prop in ro.build.version.release ro.build.version.sdk ro.product.manufacturer \
              ro.product.model ro.build.fingerprint; do
    printf '%s: ' "$prop"
    adb_do shell getprop "$prop" | tr -d '\r'
  done
} >"$out/device.txt"

capture camera-features.txt shell pm list features
capture camera-nodes.txt shell 'for n in /sys/class/video4linux/video*/name; do [ -f "$n" ] && echo "$n: $(cat "$n")"; done; true'
capture camera-before.txt shell dumpsys media.camera

watch_started=0
watch_tags='android.control.aeMode,android.control.afMode,android.control.aeState,android.control.afState,android.jpeg.orientation,android.sensor.timestamp'
if adb_do shell cmd media.camera watch start -m "$watch_tags" >"$out/camera-watch-start.txt" 2>&1; then
  watch_started=1
else
  echo 'CameraService watch unavailable; continuing with dumpsys/logcat.' >&2
fi

finish_watch() {
  if [ "$watch_started" -eq 1 ]; then
    adb_do shell cmd media.camera watch stop >/dev/null 2>&1 || true
  fi
}
trap finish_watch EXIT INT TERM

cat <<'PROMPT'

In AnonChat on this Android device:
  1. Take a photo inside the app and send it; check the camera badge after upload.
  2. Record a video inside the app and send it; check the badge after upload.
  3. Wait until BOTH uploads finish, then press Enter here.

Do not send any private photos solely for this test.
PROMPT
read -r _ || true

if [ "$watch_started" -eq 1 ]; then
  capture camera-watch.txt shell cmd media.camera watch dump
fi
capture camera-after.txt shell dumpsys media.camera
capture camera-3a.txt shell dumpsys media.camera -m 3a
capture logcat-after.txt logcat -d -t 4000 -v threadtime
finish_watch
watch_started=0
trap - EXIT INT TERM

# Keep both the complete camera dump and a compact, diff-friendly overview.
if [ -f "$out/camera-before.txt" ]; then
  grep -i -E -A 4 "$focus_regex" "$out/camera-before.txt" \
    >"$out/characteristics-focus.txt" || true
fi

cat >"$out/README.txt" <<'REPORT'
Files:
  camera-before.txt          CameraService static characteristics and HAL data
  characteristics-focus.txt  Focused fields for side-by-side diff (not exhaustive)
  camera-after.txt           CameraService state after AnonChat uploads
  camera-3a.txt              Capture metadata available from camera service
  camera-watch.txt           Selected request/result tags (Android 13+, if supported)
  logcat-after.txt           Last 4000 lines of Android logs
  camera-features.txt        Android package-manager camera features
  camera-nodes.txt           V4L2 devices if visible
  device.txt                 OS/model/build for interpretation

Warnings:
  - The camera watch is global, and the script stops it after collection.
  - Logs, build fingerprint and app messages may contain sensitive information.
    REVIEW and redact reports before sharing. Do not upload private media.
  - Dumpsys and camera-watch contents vary between Android versions/HALs.
  - This is a diagnostic snapshot. It cannot prove why AnonChat's server
    did or did not retain the camera-origin badge.
REPORT

printf '\nReport saved to %s\n' "$out"
echo "Repeat on a real phone with --label phone and compare using:"
printf '  scripts/camera-diagnostics.sh compare "%s" PATH_TO_PHONE_REPORT\n' "$out"
