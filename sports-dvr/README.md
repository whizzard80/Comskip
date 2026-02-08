# Jellyfin Sports DVR Post-Processing

Automated post-processing pipeline for Jellyfin Live TV DVR recordings. Detects sports content, removes commercials with Comskip, and organizes recordings into a clean library structure that Jellyfin serves as a TV Shows library.

## What It Does

```
Jellyfin DVR records to /tmp/
        ↓
dvr-postprocess.sh (router)
        ↓
  ┌─ Sports? ──→ comskip (sports mode) → sports-rename.sh → /sports-library/League/Season/
  │
  └─ Regular TV? → comskip (TV mode) → stays in Jellyfin DVR location
```

**For sports recordings:**
- Remuxes `.ts` → `.mp4`
- Removes commercials using Comskip with sports-tuned detection
- Parses EPG metadata (filename + NFO) to extract league, teams, and date
- Probes video resolution (720p, 1080p, 4K)
- Moves to organized library: `League/Season/ABBREV.YYYY-MM-DD.Away.vs.Home.RES.mp4`
- Generates NFO sidecar with episode metadata
- Auto-deletes truncated recordings (configurable minimum duration)

**For regular TV recordings:**
- Removes commercials using Comskip with standard TV detection
- Leaves file in place for Jellyfin's built-in TV library handling

## Output Naming Convention

```
Baseball.MLB/
  Season.2025/
    MLB.2025-08-22.Red.Sox.vs.Yankees.1080p.mp4
    MLB.2025-08-22.Red.Sox.vs.Yankees.1080p.nfo
    MLB.2025-08-22.Red.Sox.vs.Yankees.1080p.edl

Basketball.NBA/
  Season.2025-2026/
    NBA.2026-01-24.Celtics.vs.Bulls.720p.mp4

Football.NFL/
  Season.2025/
    NFL.2025-10-05.Cowboys.vs.Jets.720p.mp4
    NFL.2026-01-25.Patriots.vs.Broncos.1080p.mp4   ← Jan playoff = Season.2025

Soccer.EPL/
  Season.2025-2026/
    EPL.2026-02-06.Leeds.United.vs.Nottingham.Forest.720p.mp4
```

- **Dots** as separators (no spaces)
- **Away team first**, home team second
- **Short team names** ("Red.Sox" not "Boston Red Sox")
- **Resolution tag** at the end before extension
- **Season folders** use full years: `Season.2025-2026` for split-year leagues

## Setup

### 1. Install Dependencies

- **FFmpeg** with ffprobe (for remuxing, encoding, resolution detection)
- **Comskip** (the fork in this repo, or any comskip binary)
- **Python 3** (for EDL segment parsing)

### 2. Configure

Copy the example config and fill in your paths:

```bash
cp postprocess.conf.example postprocess.conf
```

Edit `postprocess.conf`:

```bash
# Where your organized sports library lives
SPORTS_ROOT="/path/to/your/sports-library"

# Encoding mode: software, qsv, nvenc, or vaapi
ENCODE_MODE="software"

# Optional: Jellyfin API key for auto library scans
JELLYFIN_API_KEY="your-api-key-here"
```

### 3. Set Up Jellyfin

**Library:**
- Create a new library: **Type = TV Shows**
- Point it at your `SPORTS_ROOT` path
- Disable metadata downloaders (or use TheSportsDB plugin)

**DVR Settings (Dashboard > Live TV > DVR):**
- **Recording path:** Fast local storage (e.g., `/tmp/`)
- **Post-processing application:** `/path/to/sports-dvr/dvr-postprocess.sh`
- **Post-processor command line arguments:** `"{path}"`
- **Save recording EPG metadata in NFO:** Checked (important for team name extraction)
- **Save recording EPG images:** Checked (optional, copies thumbnails)

### 4. Add Leagues

Edit `sports-leagues.conf` to add or modify league patterns:

```
# EPG Title Pattern  | Abbreviation | Folder Name      | Season Type
NFL Football*        | NFL          | Football.NFL     | year
NBA Basketball*      | NBA          | Basketball.NBA   | year-year
*Premier League*     | EPL          | Soccer.EPL       | year-year
```

Patterns use glob-style matching (case-insensitive). First match wins.

## Files

| File | Purpose |
|---|---|
| `dvr-postprocess.sh` | Main entry point — Jellyfin calls this for every recording |
| `comskip-cut.sh` | Commercial detection + removal (supports QSV/NVENC/VAAPI/software) |
| `sports-rename.sh` | Filename parsing, team lookup, resolution probe, file organization |
| `sports-leagues.conf` | League pattern configuration (EPG title → league mapping) |
| `comskip-sports.ini` | Comskip config tuned for sports broadcasts |
| `comskip-tv.ini` | Comskip config tuned for regular TV shows |
| `comskip-fork.sh` | Wrapper to use the local Comskip fork build |
| `postprocess.conf.example` | Configuration template — copy to `postprocess.conf` |

## Command-Line Options

```bash
# Normal operation:
dvr-postprocess.sh "{path}"

# Skip comskip (for testing rename/organization only):
dvr-postprocess.sh --skip-comskip "{path}"

# Override encoder:
dvr-postprocess.sh --encoder=software "{path}"

# Accept shorter recordings (30 min minimum):
dvr-postprocess.sh --min-duration=1800 "{path}"

# Skip remux (keep .ts format):
dvr-postprocess.sh --no-remux "{path}"
```

## How Team Names Are Resolved

The script uses a multi-layered approach (most reliable first):

1. **Filename** — Jellyfin DVR names like `"NBA Basketball 2026_02_08 - Miami Heat at Boston Celtics"`
2. **NFO title** — Jellyfin's EPG metadata: `<title>Miami Heat at Boston Celtics</title>`
3. **NFO plot** — Description text: `"The Boston Celtics visit the New York Knicks at MSG"`
4. **NFO genre** — Helps detect league when filename is ambiguous
5. **Time fallback** — Uses broadcast time (HHMM) when no teams can be determined

## Encoding Modes

Set `ENCODE_MODE` in `postprocess.conf`:

| Mode | Hardware | Speed | Notes |
|---|---|---|---|
| `software` | CPU (x264) | Slow | Works everywhere, no GPU needed |
| `qsv` | Intel GPU | Fast | Requires Intel Quick Sync Video |
| `nvenc` | NVIDIA GPU | Fast | Requires NVIDIA GPU + drivers |
| `vaapi` | Intel/AMD GPU | Fast | Linux only, VA-API support needed |

## License

Same as the parent Comskip project (GPL-2.0).
