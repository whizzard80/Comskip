#!/usr/bin/env bash
# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║  comskip-cut.sh - Commercial Detection + Removal                           ║
# ║                                                                            ║
# ║  Runs comskip to detect commercials, then re-encodes with FFmpeg           ║
# ║  to produce a commercial-free output file.                                 ║
# ║                                                                            ║
# ║  Supports: QSV, NVENC, VAAPI, and software (x264) encoding.               ║
# ║  Configure encoding mode in postprocess.conf.                              ║
# ║                                                                            ║
# ║  Usage: ./comskip-cut.sh <input> <output> [--ini=/path/to/config.ini]      ║
# ╚══════════════════════════════════════════════════════════════════════════════╝
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Load Configuration ─────────────────────────────────────────────────────────

CONF_FILE="${SCRIPT_DIR}/postprocess.conf"
if [[ -f "$CONF_FILE" ]]; then
    # shellcheck source=postprocess.conf
    source "$CONF_FILE"
fi

FFMPEG="${FFMPEG:-ffmpeg}"
FFPROBE="${FFPROBE:-ffprobe}"
COMSKIP_BIN="${COMSKIP_BIN:-comskip}"
ENCODE_MODE="${ENCODE_MODE:-software}"
QSV_DEV="${QSV_DEV:-/dev/dri/renderD128}"
VIDEO_BITRATE="${VIDEO_BITRATE:-4500k}"
VIDEO_MAXRATE="${VIDEO_MAXRATE:-7000k}"
VIDEO_BUFSIZE="${VIDEO_BUFSIZE:-9000k}"
AUDIO_BITRATE="${AUDIO_BITRATE:-192k}"

# ── Parse Arguments ────────────────────────────────────────────────────────────

INPUT=""
OUTPUT=""
COMSKIP_INI="${SCRIPT_DIR}/comskip-sports.ini"

for arg in "$@"; do
    case "$arg" in
        --ini=*) COMSKIP_INI="${arg#--ini=}" ;;
        *)
            if [[ -z "$INPUT" ]]; then
                INPUT="$arg"
            elif [[ -z "$OUTPUT" ]]; then
                OUTPUT="$arg"
            fi
            ;;
    esac
done

if [[ -z "$INPUT" || -z "$OUTPUT" ]]; then
    echo "Usage: $0 <input> <output> [--ini=/path/to/config.ini]"
    echo ""
    echo "Encoding modes (set ENCODE_MODE in postprocess.conf):"
    echo "  software  - CPU x264 (universal, slower)"
    echo "  qsv       - Intel Quick Sync Video"
    echo "  nvenc     - NVIDIA NVENC"
    echo "  vaapi     - VA-API (Intel/AMD on Linux)"
    exit 1
fi

BASE="$(basename "${INPUT%.*}")"
WORKDIR="$(mktemp -d)"
FCAT="${WORKDIR}/${BASE}.ffconcat"

trap 'rm -rf "$WORKDIR"' EXIT

echo "=== Comskip Commercial Removal ==="
echo "Input:   $INPUT"
echo "Output:  $OUTPUT"
echo "Config:  $(basename "$COMSKIP_INI")"
echo "Encoder: $ENCODE_MODE"
echo ""

# ── Step 1: Commercial Detection ──────────────────────────────────────────────

echo "[1/3] Detecting commercials..."
EDL="${WORKDIR}/${BASE}.edl"
"$COMSKIP_BIN" --ini="$COMSKIP_INI" --output="$WORKDIR" "$INPUT" 2>&1 | tail -5

if [[ ! -s "$EDL" ]]; then
    echo "No commercials detected. Copying input as-is."
    cp "$INPUT" "$OUTPUT"
    exit 0
fi

# ── Step 2: Build Segment List ────────────────────────────────────────────────

echo ""
echo "[2/3] Building segment list from EDL..."

python3 - "$INPUT" "$EDL" "$FCAT" "$FFPROBE" <<'PYEOF'
import sys, subprocess, os

input_file = sys.argv[1]
edl_file = sys.argv[2]
fcat_file = sys.argv[3]
ffprobe_bin = sys.argv[4]

result = subprocess.run(
    [ffprobe_bin, '-v', 'error', '-show_entries', 'format=duration',
     '-of', 'default=noprint_wrappers=1:nokey=1', input_file],
    capture_output=True, text=True)
duration = float(result.stdout.strip())

cuts = []
with open(edl_file) as f:
    for line in f:
        parts = line.strip().split()
        if len(parts) >= 3:
            cuts.append((float(parts[0]), float(parts[1])))

keep = []
prev_end = 0.0
for start, end in sorted(cuts):
    if start > prev_end + 0.1:
        keep.append((prev_end, start))
    prev_end = end
if prev_end < duration - 0.1:
    keep.append((prev_end, duration))

abs_input = os.path.abspath(input_file)
with open(fcat_file, 'w') as f:
    f.write("ffconcat version 1.0\n")
    for start, end in keep:
        f.write(f"file '{abs_input}'\n")
        f.write(f"inpoint {start:.3f}\n")
        f.write(f"outpoint {end:.3f}\n")

total_comm = sum(e - s for s, e in cuts)
total_keep = sum(e - s for s, e in keep)
print(f"  Commercials: {len(cuts)} breaks, {total_comm:.0f}s ({total_comm/60:.1f} min)")
print(f"  Content:     {len(keep)} segments, {total_keep:.0f}s ({total_keep/60:.1f} min)")
print(f"  Reduction:   {total_comm/duration*100:.1f}% removed")
PYEOF

# ── Step 3: Re-encode Without Commercials ─────────────────────────────────────

echo ""
echo "[3/3] Encoding commercial-free video ($ENCODE_MODE)..."

# Build the FFmpeg command based on encoding mode
FFMPEG_ARGS=(
    "$FFMPEG" -y -hide_banner -loglevel warning
    -f concat -safe 0 -i "$FCAT"
    -map 0:v -map 0:a?
    -fps_mode cfr
)

case "$ENCODE_MODE" in
    qsv)
        FFMPEG_ARGS=(
            "$FFMPEG" -y -hide_banner -loglevel warning
            -init_hw_device "qsv=hw:${QSV_DEV}" -filter_hw_device hw
            -f concat -safe 0 -i "$FCAT"
            -map 0:v -map 0:a?
            -fps_mode cfr
            -vf 'hwupload=extra_hw_frames=64,format=qsv'
            -c:v h264_qsv -preset medium
            -b:v "$VIDEO_BITRATE" -maxrate "$VIDEO_MAXRATE" -bufsize "$VIDEO_BUFSIZE"
            -g 120 -keyint_min 120 -force_key_frames "expr:gte(t,n_forced*2)"
        )
        ;;
    nvenc)
        FFMPEG_ARGS+=(
            -c:v h264_nvenc -preset p4 -tune hq
            -b:v "$VIDEO_BITRATE" -maxrate "$VIDEO_MAXRATE" -bufsize "$VIDEO_BUFSIZE"
            -g 120 -keyint_min 120 -force_key_frames "expr:gte(t,n_forced*2)"
        )
        ;;
    vaapi)
        FFMPEG_ARGS=(
            "$FFMPEG" -y -hide_banner -loglevel warning
            -vaapi_device "${QSV_DEV}"
            -f concat -safe 0 -i "$FCAT"
            -map 0:v -map 0:a?
            -fps_mode cfr
            -vf 'format=nv12,hwupload'
            -c:v h264_vaapi
            -b:v "$VIDEO_BITRATE" -maxrate "$VIDEO_MAXRATE" -bufsize "$VIDEO_BUFSIZE"
            -g 120 -keyint_min 120
        )
        ;;
    software|*)
        FFMPEG_ARGS+=(
            -c:v libx264 -preset medium -crf 20
            -b:v "$VIDEO_BITRATE" -maxrate "$VIDEO_MAXRATE" -bufsize "$VIDEO_BUFSIZE"
            -g 120 -keyint_min 120 -force_key_frames "expr:gte(t,n_forced*2)"
        )
        ;;
esac

# Audio settings (common to all modes)
FFMPEG_ARGS+=(
    -c:a aac -b:a "$AUDIO_BITRATE" -ar 48000 -af aresample=async=1000:first_pts=0
    -movflags +faststart
    "$OUTPUT"
)

"${FFMPEG_ARGS[@]}"

OUTPUT_SIZE=$(du -h "$OUTPUT" | cut -f1)
echo ""
echo "=== Complete ==="
echo "Output: $OUTPUT ($OUTPUT_SIZE)"
