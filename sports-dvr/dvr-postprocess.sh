#!/usr/bin/env bash
# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║  dvr-postprocess.sh - Unified Jellyfin DVR Post-Processing Router          ║
# ║                                                                            ║
# ║  Jellyfin calls this for every Live TV recording after it finishes.         ║
# ║  It detects sports vs regular TV, applies the right comskip config,        ║
# ║  remuxes .ts→.mp4, removes commercials, and routes sports recordings       ║
# ║  to an organized library (League/Season/Game naming convention).            ║
# ║                                                                            ║
# ║  Jellyfin DVR > Post-processing command:                                   ║
# ║    /path/to/dvr-postprocess.sh "%path%"                                    ║
# ║                                                                            ║
# ║  Configuration: postprocess.conf (copy postprocess.conf.example)           ║
# ╚══════════════════════════════════════════════════════════════════════════════╝
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Load Configuration ─────────────────────────────────────────────────────────

CONF_FILE="${SCRIPT_DIR}/postprocess.conf"
if [[ ! -f "$CONF_FILE" ]]; then
    echo "ERROR: Configuration file not found: $CONF_FILE"
    echo "  Copy postprocess.conf.example to postprocess.conf and fill in your paths."
    exit 1
fi
# shellcheck source=postprocess.conf
source "$CONF_FILE"

LEAGUES_CONF="${SCRIPT_DIR}/sports-leagues.conf"
LOG_FILE="${SCRIPT_DIR}/dvr-postprocess.log"

# Defaults for optional config values
SPORTS_ROOT="${SPORTS_ROOT:?Set SPORTS_ROOT in postprocess.conf}"
FFMPEG="${FFMPEG:-ffmpeg}"
FFPROBE="${FFPROBE:-ffprobe}"
MIN_DURATION_SECONDS="${MIN_DURATION_SECONDS:-3600}"
REMUX_TO_MP4="${REMUX_TO_MP4:-true}"
SKIP_COMSKIP="${SKIP_COMSKIP:-false}"
DELETE_ORIGINAL="${DELETE_ORIGINAL:-false}"
DVR_RECORDING_PATH="${DVR_RECORDING_PATH:-}"
TEMP_CLEANUP_HOURS="${TEMP_CLEANUP_HOURS:-4}"

# ── Logging ────────────────────────────────────────────────────────────────────

log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
    echo "$msg" | tee -a "$LOG_FILE"
}

# ── Parse Command-Line Overrides ───────────────────────────────────────────────
# These override postprocess.conf for this run only.
# Useful for testing or Jellyfin post-processing args.
#
# Supported flags:
#   --skip-comskip     Skip commercial detection
#   --encoder=MODE     Override ENCODE_MODE (software|qsv|nvenc|vaapi)
#   --no-remux         Skip .ts→.mp4 remux
#   --keep-original    Don't delete the original file
#   --min-duration=N   Override minimum duration (seconds)

INPUT=""
for arg in "$@"; do
    case "$arg" in
        --skip-comskip)    SKIP_COMSKIP="true" ;;
        --encoder=*)       ENCODE_MODE="${arg#--encoder=}" ;;
        --no-remux)        REMUX_TO_MP4="false" ;;
        --keep-original)   DELETE_ORIGINAL="false" ;;
        --min-duration=*)  MIN_DURATION_SECONDS="${arg#--min-duration=}" ;;
        -*)                echo "Unknown flag: $arg" ;;
        *)                 INPUT="$arg" ;;
    esac
done

if [[ -z "$INPUT" ]]; then
    echo "Usage: dvr-postprocess.sh [options] <path_to_recording>"
    echo ""
    echo "Options:"
    echo "  --skip-comskip      Skip commercial detection"
    echo "  --encoder=MODE      Override encoder (software|qsv|nvenc|vaapi)"
    echo "  --no-remux          Skip .ts to .mp4 remux"
    echo "  --keep-original     Don't delete the original recording"
    echo "  --min-duration=N    Minimum duration in seconds (default: 3600)"
    exit 1
fi

if [[ ! -f "$INPUT" ]]; then
    log "ERROR: File not found: $INPUT"
    exit 1
fi

log "=========================================="
log "DVR Post-Processing: $(basename "$INPUT")"
log "=========================================="
log "  Path: $INPUT"
log "  Size: $(du -h "$INPUT" | cut -f1)"

# ── Duration Check ─────────────────────────────────────────────────────────────
# Delete recordings shorter than MIN_DURATION_SECONDS (likely truncated)

if [[ "$MIN_DURATION_SECONDS" -gt 0 ]]; then
    duration=$("$FFPROBE" -v error -show_entries format=duration \
        -of csv=p=0 "$INPUT" 2>/dev/null | head -1 || echo "0")
    if [[ -n "$duration" && "$duration" != "N/A" ]]; then
        dur_int=$(echo "$duration" | awk '{printf "%.0f", $1}')
        dur_min=$((dur_int / 60))
        if [[ "$dur_int" -lt "$MIN_DURATION_SECONDS" ]]; then
            log "  Duration: ${dur_min} min -- BELOW MINIMUM ($(( MIN_DURATION_SECONDS / 60 )) min)"
            log "  Deleting truncated recording."
            rm -f "$INPUT"
            # Also delete any sidecars Jellyfin may have created
            rm -f "${INPUT%.*}.nfo" "${INPUT%.*}.edl" "${INPUT%.*}-thumb.jpg"
            log "  Done (deleted)."
            exit 0
        fi
        log "  Duration: ${dur_min} min"
    fi
fi

# ── Detect Content Type ───────────────────────────────────────────────────────

detect_sports() {
    local filename="$1"
    local stem
    stem=$(basename "$filename")
    stem="${stem%.*}"
    stem=$(echo "$stem" | sed 's/\.work$//; s/^Live[[:space:]]*//' | sed 's/[[:space:]]\{2,\}/ /g')

    while IFS='|' read -r pattern abbrev folder season_type; do
        [[ "$pattern" =~ ^[[:space:]]*# ]] && continue
        [[ -z "$pattern" ]] && continue
        pattern=$(echo "$pattern" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        [[ -z "$pattern" ]] && continue
        local regex
        regex=$(echo "$pattern" | sed 's/\./\\./g; s/\*/.*/g; s/\?/./g')
        if echo "$stem" | grep -iqE "${regex}" 2>/dev/null; then
            return 0
        fi
    done < "$LEAGUES_CONF"

    return 1
}

IS_SPORTS=false
if detect_sports "$INPUT"; then
    IS_SPORTS=true
    log "  Content: SPORTS"
else
    log "  Content: REGULAR TV"
fi

# ── Remux .ts → .mp4 ──────────────────────────────────────────────────────────

WORKING_FILE="$INPUT"
ORIGINAL_INPUT="$INPUT"

if [[ "$REMUX_TO_MP4" == "true" ]]; then
    ext="${INPUT##*.}"
    if [[ "$ext" != "mp4" ]]; then
        mp4_out="${INPUT%.*}.mp4"
        log "  Remuxing ${ext} → mp4..."
        if "$FFMPEG" -y -hide_banner -loglevel warning \
            -i "$INPUT" -c copy -movflags +faststart "$mp4_out" 2>&1 | tail -3; then
            if [[ -f "$mp4_out" && -s "$mp4_out" ]]; then
                rm -f "$INPUT"
                WORKING_FILE="$mp4_out"
                log "  Remux complete: $(du -h "$mp4_out" | cut -f1)"
            else
                log "  WARNING: Remux failed, keeping original"
                rm -f "$mp4_out"
            fi
        else
            log "  WARNING: Remux failed, keeping original"
            rm -f "$mp4_out" 2>/dev/null
        fi
    fi
fi

# ── Commercial Detection + Removal ────────────────────────────────────────────

if [[ "$SKIP_COMSKIP" != "true" ]]; then
    COMSKIP_OUTPUT="${WORKING_FILE%.*}-comskip.mp4"

    if $IS_SPORTS; then
        log "  Comskip: sports mode"
        INI_FLAG="--ini=${SCRIPT_DIR}/comskip-sports.ini"
    else
        log "  Comskip: TV mode"
        if [[ -f "${SCRIPT_DIR}/comskip-tv.ini" ]]; then
            INI_FLAG="--ini=${SCRIPT_DIR}/comskip-tv.ini"
        else
            INI_FLAG="--ini=${SCRIPT_DIR}/comskip-sports.ini"
            log "  WARNING: comskip-tv.ini not found, using sports config"
        fi
    fi

    if "${SCRIPT_DIR}/comskip-cut.sh" "$WORKING_FILE" "$COMSKIP_OUTPUT" "$INI_FLAG" 2>&1 | tee -a "$LOG_FILE"; then
        if [[ -f "$COMSKIP_OUTPUT" && -s "$COMSKIP_OUTPUT" ]]; then
            rm -f "$WORKING_FILE"
            WORKING_FILE="$COMSKIP_OUTPUT"
            log "  Commercials removed."
        else
            log "  WARNING: Comskip output empty, keeping original."
            rm -f "$COMSKIP_OUTPUT"
        fi
    else
        log "  WARNING: Comskip failed, proceeding without commercial removal."
        rm -f "$COMSKIP_OUTPUT" 2>/dev/null
    fi
else
    log "  Comskip: SKIPPED"
fi

# ── Route the File ─────────────────────────────────────────────────────────────

if $IS_SPORTS; then
    log "  Routing to sports library..."
    "${SCRIPT_DIR}/sports-rename.sh" "$WORKING_FILE" "$ORIGINAL_INPUT" 2>&1 | tee -a "$LOG_FILE"
else
    log "  Regular TV stays in place: $(basename "$WORKING_FILE")"
fi

log "  Post-processing complete."

# ── Temp Directory Cleanup ────────────────────────────────────────────────────
# Clean up old recordings from the DVR temp directory to prevent disk fill-up.
# Only runs if DVR_RECORDING_PATH is set in postprocess.conf.
# Deletes media/sidecar files older than TEMP_CLEANUP_HOURS (default 4).

if [[ -n "$DVR_RECORDING_PATH" && -d "$DVR_RECORDING_PATH" && "$TEMP_CLEANUP_HOURS" -gt 0 ]]; then
    cleanup_mins=$((TEMP_CLEANUP_HOURS * 60))

    # Count old media files
    old_files=$(find "$DVR_RECORDING_PATH" -type f \
        \( -name "*.ts" -o -name "*.mp4" -o -name "*.mkv" -o -name "*.avi" \
           -o -name "*.nfo" -o -name "*.edl" -o -name "*.png" -o -name "*.jpg" \
           -o -name "*.jpeg" -o -name "*.srt" -o -name "*.vtt" \) \
        -mmin +"$cleanup_mins" 2>/dev/null)

    old_count=$(echo "$old_files" | grep -c . 2>/dev/null || echo 0)

    if [[ "$old_count" -gt 0 ]]; then
        log "  Temp cleanup: removing $old_count files older than ${TEMP_CLEANUP_HOURS}h from $DVR_RECORDING_PATH"

        # Delete old media/sidecar files
        find "$DVR_RECORDING_PATH" -type f \
            \( -name "*.ts" -o -name "*.mp4" -o -name "*.mkv" -o -name "*.avi" \
               -o -name "*.nfo" -o -name "*.edl" -o -name "*.png" -o -name "*.jpg" \
               -o -name "*.jpeg" -o -name "*.srt" -o -name "*.vtt" \) \
            -mmin +"$cleanup_mins" -delete 2>/dev/null

        # Remove empty subdirectories left behind
        find "$DVR_RECORDING_PATH" -mindepth 1 -type d -empty -delete 2>/dev/null

        log "  Temp cleanup: done."
    fi
fi

log ""
