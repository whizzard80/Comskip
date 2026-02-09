# Baseline Test Results - Fork vs System Comskip

## Test File
- **File**: `basketball-game-test.mp4`
- **Size**: 5.0GB
- **Frame Rate**: 60.000 fps
- **Resolution**: 1280x720

## Fork Version
- **Version**: Comskip 0.83.001 (fork)
- **System Version**: 0.82.011 (for comparison)

## Detection Methods Used
1. Black Frame
2. Logo (Give up after 2000 seconds)
3. Resolution Change
4. Closed Captions
5. Aspect Ratio
6. Silence

## Results

### Logo Detection: ✅ WORKING
- Logo found at frame 8280
- Logo position: X=1163-1256, Y=19-69 (top-right corner)
- **16+ logo blocks identified** throughout the video
- Logo blocks range from 3 seconds to 8+ minutes

### Commercial Detection: ❌ FAILED
- **Output file**: `basketball-game-test.txt` = **0 bytes (empty)**
- **No commercials detected**
- This confirms the problem: Comskip's heuristics don't work for sports breaks

## Analysis

### Why Detection Failed

1. **Logo Present During Game**: 
   - Logo is present during actual gameplay (logo blocks identified)
   - Traditional Comskip logic: "logo present = show content"
   - But sports breaks ALSO have logo, so this heuristic fails

2. **Sports Break Characteristics**:
   - Breaks occur during timeouts/halftime
   - Logo often remains visible
   - No distinct black frames or scene changes
   - Audio may have crowd noise or announcer commentary
   - Different temporal patterns than TV commercials

3. **Non-Logo Segments**:
   - Between logo blocks, there are "nonlogo" segments
   - These might be commercial breaks, but they're not being classified as commercials
   - Scoring system doesn't recognize sports break patterns

## Logo Block Pattern Observed

```
Logo Block 0:  frames 5460-14340   (2:23 length)
Nonlogo:       3:41 length
Logo Block 1:  frames 27600-37980  (2:48 length)
Nonlogo:       1:13 length
Logo Block 2:  frames 42360-57600  (4:09 length)
Nonlogo:       0:07 length
...
```

The "nonlogo" segments between logo blocks are likely commercial breaks, but they're not being detected because:
- They don't meet the commercial scoring threshold
- They may have logo present (scorebug/overlay)
- Audio patterns differ from TV commercials

## Next Steps for Sports Detection

1. **Audio Analysis Enhancement**
   - Detect sustained silence or music (commercials)
   - Detect crowd noise patterns (game vs commercial)
   - Detect announcer voice patterns

2. **Temporal Pattern Recognition**
   - Basketball timeout pattern: ~2-3 minutes
   - Halftime pattern: ~15-20 minutes
   - Identify breaks by duration and context

3. **Visual Scorebug Detection**
   - Detect when scorebug disappears (commercial indicator)
   - Detect clock/score changes vs static commercial screens

4. **Enhanced Scoring**
   - Modify scoring to recognize sports break patterns
   - Lower threshold for segments without game audio
   - Consider logo presence differently for sports

## Conclusion

✅ **Fork builds and runs successfully**
✅ **Logo detection works**
❌ **Commercial detection fails for sports** (as expected)

This confirms we need to implement sports-specific detection heuristics. The baseline establishes that the current detection methods are insufficient for sports content.
