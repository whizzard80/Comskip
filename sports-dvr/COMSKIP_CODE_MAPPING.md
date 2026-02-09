# Comskip Code Mapping for Sports Detection Enhancement

## Overview
This document maps the existing Comskip detection architecture to identify integration points for sports-specific commercial detection.

## Core Detection Methods (comskip.c)

### Detection Method Flags (Lines 38-46)
```c
#define BLACK_FRAME		1
#define LOGO			2
#define SCENE_CHANGE	4
#define RESOLUTION_CHANGE	8
#define CC				16
#define AR				32
#define SILENCE			64
#define CUTSCENE		128
```

Default active methods (line 610):
```c
commDetectMethod = BLACK_FRAME + LOGO + RESOLUTION_CHANGE + AR + SILENCE + (PROCESS_CC ? CC : 0);
```

## Key Data Structures

### frame_info (Lines 160-189)
Per-frame analysis data:
- `brightness` - Frame brightness (0-255)
- `volume` - Audio volume level
- `isblack` - Bitmask of detection causes (C_b, C_u, C_v, C_s, C_r, C_t)
- `logo_present` - Boolean logo detection
- `currentGoodEdge` - Logo edge quality score
- `schange_percent` - Scene change percentage
- `ar_ratio` - Aspect ratio
- `uniform` - Frame uniformity metric
- `pts` - Presentation timestamp

### block_info (Lines 240-269)
Segmented blocks between cutpoints:
- `f_start`, `f_end` - Frame range
- `score` - Commercial likelihood score (>1.05 = commercial)
- `length` - Duration in seconds
- `logo` - Logo fraction (0.0-1.0)
- `volume`, `silence`, `brightness` - Aggregated metrics
- `cause` - Bitmask of detection causes
- `iscommercial` - Final classification

## Detection Flow

### 1. Frame Processing (ProcessFrame, ~line 10600)
For each frame:
- Extract brightness, volume, scene change metrics
- Check for black frames (C_b), uniform frames (C_u)
- Detect silence (C_v) if `volume < max_silence`
- Detect scene changes (C_s) based on brightness jumps
- Logo detection via `SearchForLogoEdges()` (~line 11500)
- Aspect ratio changes (C_a)

### 2. Black Frame Detection (InsertBlackFrame, ~line 10700)
Frames marked with detection causes are inserted into `black[]` array:
- `C_b` - Black frame (brightness < max_avg_brightness)
- `C_u` - Uniform frame (non_uniformity threshold)
- `C_v` - Silence (volume < max_silence)
- `C_s` - Scene change
- `C_r` - Resolution change
- `C_t` - Cutscene match

### 3. Block Segmentation (BuildBlocks, ~line 15000)
Black frames are grouped into blocks:
- Blocks created between consecutive cutpoints
- Logo presence calculated per block
- Audio/video metrics aggregated

### 4. Block Scoring (WeighBlocks, ~line 4832)
Each block receives a commercial score:
- Base score starts at 1.0
- **Logo modifier**: Blocks without logo get higher score (punish_no_logo)
- **Length modifiers**: 
  - `excessive_length_modifier` (0.01) for very long blocks
  - `length_strict_modifier` (3.0) for strict blocks
- **Audio modifiers**: Volume/silence differences from average
- **Aspect ratio**: Wrong AR increases score (`ar_wrong_modifier = 2.0`)
- **Scene change rate**: Low schange_rate increases score
- **Brightness**: Dark blocks get `dark_block_modifier` (0.3)

### 5. Heuristics (WeighBlocks, lines 5530-6000)
Post-scoring adjustments:
- H1: Discard short blocks between two commercial blocks
- H2: Add short blocks after strict commercials
- H3-H8: Various edge case handling

### 6. Commercial Classification (BuildCommercial, ~line 7213)
Blocks with `score > global_threshold` (default 1.05) are marked as commercials.

## Key Configuration Parameters (INI file)

### Audio Detection
- `max_volume` (default 500) - Threshold for silence detection
- `max_silence` (default 100) - Silence threshold
- `min_silence` (default 1) - Minimum silence frames to trigger
- `volume_slip` (default 40) - Frames to check around cutpoints

### Visual Detection
- `max_brightness` (default 60) - Black frame threshold
- `max_avg_brightness` (default 19) - Average brightness for black
- `non_uniformity` (default 500) - Uniformity threshold
- `brightness_jump` (default 200) - Scene change threshold
- `schange_threshold` (default 90) - Scene change percentage

### Logo Detection
- `logo_threshold` (default 0.80) - Logo edge quality threshold
- `logo_percentage_threshold` (default 0.25) - Minimum logo presence
- `logo_fraction` (default 0.40) - Logo fraction for show segments
- `shrink_logo` (default 5.0) - Seconds to shrink around logo

### Block Scoring
- `global_threshold` (default 1.05) - Commercial classification threshold
- `min_commercialbreak` (default 20s) - Minimum break length
- `max_commercialbreak` (default 600s) - Maximum break length
- `min_show_segment_length` (default 120s) - Minimum show segment

## Integration Points for Sports Detection

### 1. Audio Analysis Enhancement
**Location**: `ProcessFrame()` audio extraction (~line 10400)
**Current**: Simple volume level detection
**Enhancement**: 
- Add frequency analysis for crowd noise detection
- Detect announcer voice patterns (sustained speech vs silence)
- Track audio energy distribution (crowd roar vs commercial music)

**Hook Point**: After `frame[frame_count].volume` calculation, add:
```c
// New: Sports audio analysis
if (commDetectMethod & SPORTS_AUDIO) {
    frame[frame_count].crowd_energy = AnalyzeCrowdNoise(audio_samples);
    frame[frame_count].announcer_present = DetectAnnouncerVoice(audio_samples);
}
```

### 2. Visual Scorebug Detection
**Location**: `ProcessFrame()` visual analysis (~line 10500)
**Current**: Logo detection via edge detection
**Enhancement**:
- Extract scorebug region (typically top-right or bottom overlay)
- Detect clock/score text presence
- Track scorebug stability (commercials often remove it)

**Hook Point**: After logo detection, add:
```c
// New: Scorebug detection
if (commDetectMethod & SPORTS_VISUAL) {
    frame[frame_count].scorebug_present = DetectScorebug(frame_data);
    frame[frame_count].clock_visible = DetectClock(frame_data);
}
```

### 3. Temporal Pattern Detection
**Location**: `WeighBlocks()` scoring (~line 4832)
**Enhancement**:
- Detect timeout/halftime patterns (sustained breaks)
- Track game state transitions
- Identify commercial break patterns (e.g., basketball timeouts ~2-3 min)

**Hook Point**: Add new scoring modifier:
```c
// New: Sports temporal patterns
if (commDetectMethod & SPORTS_TEMPORAL) {
    double sports_score = AnalyzeSportsPattern(block);
    cblock[i].score *= sports_score;
}
```

### 4. Block Classification Enhancement
**Location**: `BuildCommercial()` (~line 7213)
**Enhancement**:
- Add sports-specific heuristics
- Consider game context (time remaining, score changes)

## Output Formats

### EDL Format (OutputEdl, ~line 6982)
```c
fprintf(edl_file, "%.2f\t%.2f\t%d\n", start_time, end_time, skip_field);
```
**Jellyfin Compatibility**: EDL format is standard, but need to ensure:
- Proper XML escaping for filenames (`EscapeXmlFilename()` exists at line 6065)
- No unescaped characters in time values

### Chapters Format (OutputChapters, ~line 6130)
```c
fprintf(chapters_file, "%ld\n", frame_number);
```
**Jellyfin Compatibility**: Simple frame numbers, should be safe

### XML Format (mkvtoolnix_chapters_file, ~line 6698)
```c
fprintf(mkvtoolnix_chapters_file, "<?xml version=\"1.0\" encoding=\"ISO-8859-1\"?>\n<Chapters>\n");
```
**Jellyfin Compatibility**: 
- Uses ISO-8859-1 encoding (may need UTF-8)
- Has XML escaping function (`EscapeXmlFilename()`)
- Need to verify all text fields are properly escaped

## Recommended Sports Detection Implementation

### Phase 1: Lightweight Audio Analysis
1. Extend audio volume analysis to detect:
   - Sustained low volume (timeout/halftime)
   - Crowd noise energy (FFT-based)
   - Announcer speech patterns (voice activity detection)

### Phase 2: Visual Scorebug Detection (Optional ML)
1. Simple approach: Template matching for scorebug region
2. ML approach: OCR for clock/score text (optional, can be external helper)

### Phase 3: Temporal Heuristics
1. Pattern recognition for break types:
   - Basketball timeout: ~2-3 minutes
   - Halftime: ~15-20 minutes
   - Baseball inning break: ~2-3 minutes
2. Game state tracking (score changes, clock progression)

## Files to Modify

1. **comskip.c** - Main detection logic
   - Add new detection method flags
   - Extend frame_info structure
   - Add sports detection functions
   - Enhance WeighBlocks() scoring

2. **comskip.h** - Header definitions
   - Add new constants and structures

3. **comskip.ini** - Configuration
   - Add sports-specific parameters
   - New detection method combinations

4. **Output functions** - Ensure Jellyfin compatibility
   - Verify XML escaping
   - Test EDL format
   - Check encoding issues
