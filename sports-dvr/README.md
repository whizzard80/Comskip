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
- Auto-detects source bitrate for quality-matched re-encoding
- Cleans up old temp recordings from the DVR directory

**For regular TV recordings:**
- Removes commercials using Comskip with standard TV detection
- Leaves file in place for Jellyfin's built-in TV library handling

## Pipeline Flow

```
Jellyfin DVR finishes recording
        ↓
dvr-postprocess.sh (router)
        ↓
  1. Duration check — delete truncated recordings
  2. Detect content type (sports vs regular TV)
  3. Remux .ts → .mp4
  4. comskip-cut.sh — detect + remove commercials
  5. sports-rename.sh — parse metadata, organize, generate NFO
  6. Jellyfin library scan (if API key configured)
  7. Temp directory cleanup
```

## Output Naming Convention

### Filename Format

```
ABBREV.YYYY-MM-DD.Away.vs.Home.RES.mp4
```

| Component | Description | Example |
|---|---|---|
| `ABBREV` | League abbreviation from `sports-leagues.conf` | `NFL`, `NBA`, `EPL`, `UFC` |
| `YYYY-MM-DD` | ISO date of the event | `2026-02-08` |
| `Away.vs.Home` | Short team names, away first | `Celtics.vs.Bulls` |
| `RES` | Video resolution (auto-detected) | `720p`, `1080p`, `4K` |

For non-matchup events (All-Star games, derbies, etc.), the teams are replaced with an event description:

```
UFC.2025-11-15.UFC.298.Main.Card.1080p.mp4
WWE.2025-04-19.WrestleMania.41.Night.1.720p.mp4
F1.2025-03-16.Australian.Grand.Prix.Race.1080p.mp4
```

When no teams or event description can be determined, broadcast time (HHMM) is used as a fallback:

```
NBA.2026-02-08.1930.720p.mp4
```

### Directory Structure

```
SPORTS_ROOT/
  League.Folder/
    Season.YYYY/  or  Season.YYYY-YYYY/
      ABBREV.YYYY-MM-DD.Away.vs.Home.RES.mp4
      ABBREV.YYYY-MM-DD.Away.vs.Home.RES.nfo
      ABBREV.YYYY-MM-DD.Away.vs.Home.RES.edl
```

### Full Example

```
/media/sports/
  Baseball.MLB/
    Season.2025/
      MLB.2025-08-22.Red.Sox.vs.Yankees.1080p.mp4
      MLB.2025-08-22.Red.Sox.vs.Yankees.1080p.nfo
      MLB.2025-08-22.Red.Sox.vs.Yankees.1080p.edl

  Basketball.NBA/
    Season.2025-2026/
      NBA.2026-01-24.Celtics.vs.Bulls.720p.mp4
      NBA.2026-02-08.Heat.vs.Celtics.1080p.mp4

  Football.NFL/
    Season.2025/
      NFL.2025-10-05.Cowboys.vs.Jets.720p.mp4
      NFL.2026-01-25.Patriots.vs.Broncos.1080p.mp4   ← Jan playoff = Season.2025

  Soccer.EPL/
    Season.2025-2026/
      EPL.2026-02-06.Leeds.United.vs.Nottingham.Forest.720p.mp4

  Hockey.NHL/
    Season.2025-2026/
      NHL.2026-01-10.Bruins.vs.Rangers.1080p.mp4

  Combat.Sports/
    Season.2025/
      UFC.2025-11-15.UFC.298.Main.Card.1080p.mp4
      BOX.2025-03-01.Canelo.vs.Munguia.720p.mp4

  Motorsports/
    Season.2025/
      F1.2025-03-16.Australian.Grand.Prix.Race.1080p.mp4

  Wrestling.WWE/
    Season.2025/
      WWE.2025-04-19.WrestleMania.41.Night.1.720p.mp4

  Unsorted/
      Unknown.Event.2026-02-08.720p.mp4   ← no league match found
```

### Naming Rules

- **Dots** as separators (no spaces, no underscores)
- **Away team first**, home team second (matches broadcast convention)
- **Short team names** — "Red.Sox" not "Boston Red Sox", "Celtics" not "Boston Celtics"
- **Resolution tag** at the end before extension (auto-detected via ffprobe)
- **No special characters** — avoids Jellyfin XML issues (`< > : " / \ | ? * &` all stripped)
- **Collision handling** — duplicate filenames get a numeric suffix (`.2.mp4`, `.3.mp4`)
- **Unsorted folder** — recordings that don't match any league pattern land here for manual sorting

### Season Folder Logic

| Season type | Months | Example |
|---|---|---|
| `year` (NFL, MLB) | Full year; NFL Jan-Feb games belong to previous season | `Season.2025` |
| `year-year` (NBA, NHL, EPL) | Aug+ starts new season; Jan-Jul belongs to season that started previous Aug | `Season.2025-2026` |

### Sidecar Files

Each recording produces up to 3 files:

| Extension | Purpose | Used by |
|---|---|---|
| `.mp4` | The video file | Jellyfin playback |
| `.nfo` | Episode metadata (title, date, genre, plot) | Jellyfin metadata scanner |
| `.edl` | Commercial skip markers (start/end timestamps) | Jellyfin EDL plugin |

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

# Video bitrate: "auto" probes source and matches, or set explicit (e.g., "4500k")
VIDEO_BITRATE="auto"

# Optional: Jellyfin API key for auto library scans
JELLYFIN_API_KEY="your-api-key-here"

# Optional: DVR temp directory cleanup (delete old recordings after N hours)
DVR_RECORDING_PATH="/path/to/jellyfin/dvr/temp"
TEMP_CLEANUP_HOURS=4
```

### 3. Set Up Jellyfin

**Sports Library (Dashboard > Libraries > Add):**
- **Content type:** TV Shows
- **Folders:** Your `SPORTS_ROOT` path (e.g., `/media/sports`)
- **Preferred language:** Your language
- **Enable real-time monitoring:** On (picks up new files automatically)
- **Metadata downloaders:** Disable all (the pipeline generates its own NFO files).
  Optionally enable TheSportsDB plugin if you want poster art.
- **NFO Settings:** Enable "Read NFO files" so Jellyfin uses the generated metadata

Each league folder appears as a "show," each season folder as a season, and each
game file as an episode. Jellyfin reads the `.nfo` sidecar for title, date, and genre.

**DVR Settings (Dashboard > Live TV > DVR):**
- **Recording path:** Fast local storage (e.g., `/tmp/` or a dedicated DVR temp directory)
- **Post-processing application:** `/path/to/sports-dvr/dvr-postprocess.sh`
- **Post-processor command line arguments:** `"{path}"`
- **Save recording EPG metadata in NFO:** Checked (important for team name extraction)
- **Save recording EPG images:** Checked (optional, copies thumbnails)
- **Start when possible:** 2 minutes before (catches the very start of broadcasts)
- **Stop when possible:** 15 minutes after (covers overtime, extra innings, penalties)

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
| `COMSKIP_CODE_MAPPING.md` | Comskip source code architecture mapping for sports detection |
| `BASELINE_RESULTS.md` | Baseline test results comparing fork vs system Comskip |

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
