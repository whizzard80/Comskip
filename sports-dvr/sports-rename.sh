#!/usr/bin/env bash
# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║  sports-rename.sh - Sports DVR File Organizer                              ║
# ║                                                                            ║
# ║  Parses Jellyfin DVR recording filenames, detects the league/sport,        ║
# ║  extracts team names, probes video resolution, generates NFO metadata,     ║
# ║  and moves the file to an organized library structure:                     ║
# ║                                                                            ║
# ║    League/Season/ABBREV.YYYY-MM-DD.Away.vs.Home.RES.mp4                   ║
# ║                                                                            ║
# ║  Usage: sports-rename.sh <video_file> [original_dvr_filename]              ║
# ╚══════════════════════════════════════════════════════════════════════════════╝
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Load Configuration ─────────────────────────────────────────────────────────

CONF_FILE="${SCRIPT_DIR}/postprocess.conf"
if [[ -f "$CONF_FILE" ]]; then
    # shellcheck source=postprocess.conf
    source "$CONF_FILE"
fi

SPORTS_ROOT="${SPORTS_ROOT:?Set SPORTS_ROOT in postprocess.conf}"
CONF="${SCRIPT_DIR}/sports-leagues.conf"
FFPROBE="${FFPROBE:-ffprobe}"
JELLYFIN_URL="${JELLYFIN_URL:-http://localhost:8096}"
JELLYFIN_API_KEY="${JELLYFIN_API_KEY:-}"
LOG_FILE="${SCRIPT_DIR}/sports-rename.log"

# ── Logging ────────────────────────────────────────────────────────────────────

log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
    echo "$msg" | tee -a "$LOG_FILE"
}

# ── Resolution Detection ──────────────────────────────────────────────────────

get_resolution_tag() {
    local file="$1"
    local height
    height=$("$FFPROBE" -v error -select_streams v:0 -show_entries stream=height \
        -of csv=p=0 "$file" 2>/dev/null | head -1)
    case "$height" in
        2160) echo "4K" ;;
        1440) echo "1440p" ;;
        1080) echo "1080p" ;;
        720)  echo "720p" ;;
        480)  echo "480p" ;;
        360)  echo "360p" ;;
        "")   echo "" ;;
        *)    echo "${height}p" ;;
    esac
}

# ── Filename Sanitization ─────────────────────────────────────────────────────

sanitize() {
    local name="$1"
    # Strip "Live  " prefix
    name=$(echo "$name" | sed -E 's/^Live[[:space:]]+//')
    # Replace spaces/underscores with dots
    name=$(echo "$name" | sed -E 's/[[:space:]_]+/./g')
    # Remove XML-unsafe and filesystem-unsafe characters
    name=$(echo "$name" | sed -E "s/[<>:\"\/\\|?*&']+//g")
    # Collapse multiple dots
    name=$(echo "$name" | sed -E 's/\.{2,}/./g')
    # Trim leading/trailing dots
    name=$(echo "$name" | sed -E 's/^\.+|\.+$//g')
    echo "$name"
}

# ── League Detection ──────────────────────────────────────────────────────────

lookup_league() {
    local title="$1"
    local title_lower
    title_lower=$(echo "$title" | tr '[:upper:]' '[:lower:]')

    while IFS='|' read -r pattern abbrev folder season_type; do
        # Skip comments and blank lines
        [[ "$pattern" =~ ^[[:space:]]*# ]] && continue
        [[ -z "$pattern" ]] && continue

        # Trim whitespace
        pattern=$(echo "$pattern" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        abbrev=$(echo "$abbrev" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        folder=$(echo "$folder" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        season_type=$(echo "$season_type" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

        [[ -z "$pattern" || -z "$abbrev" ]] && continue

        # Convert glob pattern to case-insensitive grep regex
        local regex
        regex=$(echo "$pattern" | sed 's/\./\\./g; s/\*/.*/g; s/\?/./g')

        if echo "$title" | grep -iqE "^${regex}$" 2>/dev/null || \
           echo "$title" | grep -iqE "${regex}" 2>/dev/null; then
            echo "${abbrev}|${folder}|${season_type}"
            return 0
        fi
    done < "$CONF"

    return 1
}

# ── Season Calculation ─────────────────────────────────────────────────────────

compute_season() {
    local date_str="$1"  # YYYY-MM-DD
    local season_type="$2"
    local folder="$3"
    local year month
    year=$(echo "$date_str" | cut -d- -f1)
    month=$(echo "$date_str" | cut -d- -f2 | sed 's/^0//')

    if [[ "$season_type" == "year" ]]; then
        # NFL: Jan-Feb games belong to previous year's season
        if [[ "$folder" == *NFL* || "$folder" == *Football* ]] && [[ "$month" -le 2 ]]; then
            echo "Season.$((year - 1))"
        else
            echo "Season.${year}"
        fi
    else
        # Split-year: Aug+ = new season
        if [[ "$month" -ge 8 ]]; then
            echo "Season.${year}-$((year + 1))"
        else
            echo "Season.$((year - 1))-${year}"
        fi
    fi
}

# ── Team Name Shortening ──────────────────────────────────────────────────────

short_team() {
    local name="$1"
    local lower
    lower=$(echo "$name" | tr '[:upper:]' '[:lower:]' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

    # Lookup table for common team name abbreviations
    case "$lower" in
        # MLB
        "boston red sox"|"red sox") echo "Red.Sox" ;;
        "new york yankees"|"yankees") echo "Yankees" ;;
        "houston astros"|"astros") echo "Astros" ;;
        "miami marlins"|"marlins") echo "Marlins" ;;
        "baltimore orioles"|"orioles") echo "Orioles" ;;
        "tampa bay rays"|"rays") echo "Rays" ;;
        "toronto blue jays"|"blue jays") echo "Blue.Jays" ;;
        "detroit tigers"|"tigers") echo "Tigers" ;;
        "cleveland guardians"|"guardians") echo "Guardians" ;;
        "los angeles dodgers"|"dodgers") echo "Dodgers" ;;
        "cincinnati reds"|"reds") echo "Reds" ;;
        "pittsburgh pirates"|"pirates") echo "Pirates" ;;
        "arizona diamondbacks"|"diamondbacks") echo "Diamondbacks" ;;
        "athletics"|"oakland athletics") echo "Athletics" ;;
        "new york mets"|"mets") echo "Mets" ;;
        "chicago cubs"|"cubs") echo "Cubs" ;;
        "chicago white sox"|"white sox") echo "White.Sox" ;;
        "st. louis cardinals"|"cardinals") echo "Cardinals" ;;
        "san francisco giants"|"giants") echo "Giants" ;;
        "san diego padres"|"padres") echo "Padres" ;;
        "philadelphia phillies"|"phillies") echo "Phillies" ;;
        "atlanta braves"|"braves") echo "Braves" ;;
        "minnesota twins"|"twins") echo "Twins" ;;
        "seattle mariners"|"mariners") echo "Mariners" ;;
        "texas rangers"|"rangers") echo "Rangers" ;;
        "colorado rockies"|"rockies") echo "Rockies" ;;
        "kansas city royals"|"royals") echo "Royals" ;;
        "los angeles angels"|"angels") echo "Angels" ;;
        "washington nationals"|"nationals") echo "Nationals" ;;
        "milwaukee brewers"|"brewers") echo "Brewers" ;;
        # NBA
        "boston celtics"|"celtics") echo "Celtics" ;;
        "dallas mavericks"|"mavericks") echo "Mavericks" ;;
        "denver nuggets"|"nuggets") echo "Nuggets" ;;
        "new york knicks"|"knicks") echo "Knicks" ;;
        "oklahoma city thunder"|"thunder") echo "Thunder" ;;
        "san antonio spurs"|"spurs") echo "Spurs" ;;
        "miami heat"|"heat") echo "Heat" ;;
        "portland trail blazers"|"trail blazers") echo "Trail.Blazers" ;;
        "atlanta hawks"|"hawks") echo "Hawks" ;;
        "chicago bulls"|"bulls") echo "Bulls" ;;
        "golden state warriors"|"warriors") echo "Warriors" ;;
        "los angeles lakers"|"lakers") echo "Lakers" ;;
        "los angeles clippers"|"clippers") echo "Clippers" ;;
        "brooklyn nets"|"nets") echo "Nets" ;;
        "phoenix suns"|"suns") echo "Suns" ;;
        "milwaukee bucks"|"bucks") echo "Bucks" ;;
        "philadelphia 76ers"|"76ers"|"sixers") echo "76ers" ;;
        "toronto raptors"|"raptors") echo "Raptors" ;;
        "indiana pacers"|"pacers") echo "Pacers" ;;
        "memphis grizzlies"|"grizzlies") echo "Grizzlies" ;;
        "sacramento kings"|"kings") echo "Kings" ;;
        "charlotte hornets"|"hornets") echo "Hornets" ;;
        "new orleans pelicans"|"pelicans") echo "Pelicans" ;;
        "minnesota timberwolves"|"timberwolves") echo "Timberwolves" ;;
        "detroit pistons"|"pistons") echo "Pistons" ;;
        "orlando magic"|"magic") echo "Magic" ;;
        "utah jazz"|"jazz") echo "Jazz" ;;
        "cleveland cavaliers"|"cavaliers"|"cavs") echo "Cavaliers" ;;
        "washington wizards"|"wizards") echo "Wizards" ;;
        "houston rockets"|"rockets") echo "Rockets" ;;
        # NFL
        "carolina panthers"|"panthers") echo "Panthers" ;;
        "new england patriots"|"patriots") echo "Patriots" ;;
        "dallas cowboys"|"cowboys") echo "Cowboys" ;;
        "new york jets"|"jets") echo "Jets" ;;
        "kansas city chiefs"|"chiefs") echo "Chiefs" ;;
        "jacksonville jaguars"|"jaguars") echo "Jaguars" ;;
        "los angeles rams"|"rams") echo "Rams" ;;
        "seattle seahawks"|"seahawks") echo "Seahawks" ;;
        "washington commanders"|"commanders") echo "Commanders" ;;
        "los angeles chargers"|"chargers") echo "Chargers" ;;
        "tennessee titans"|"titans") echo "Titans" ;;
        "las vegas raiders"|"raiders") echo "Raiders" ;;
        "denver broncos"|"broncos") echo "Broncos" ;;
        "new york giants") echo "Giants" ;;
        "buffalo bills"|"bills") echo "Bills" ;;
        "baltimore ravens"|"ravens") echo "Ravens" ;;
        "pittsburgh steelers"|"steelers") echo "Steelers" ;;
        "san francisco 49ers"|"49ers"|"niners") echo "49ers" ;;
        "green bay packers"|"packers") echo "Packers" ;;
        "minnesota vikings"|"vikings") echo "Vikings" ;;
        "chicago bears"|"bears") echo "Bears" ;;
        "detroit lions"|"lions") echo "Lions" ;;
        "indianapolis colts"|"colts") echo "Colts" ;;
        "houston texans"|"texans") echo "Texans" ;;
        "new orleans saints"|"saints") echo "Saints" ;;
        "tampa bay buccaneers"|"buccaneers"|"bucs") echo "Buccaneers" ;;
        "atlanta falcons"|"falcons") echo "Falcons" ;;
        "arizona cardinals") echo "Cardinals" ;;
        "cincinnati bengals"|"bengals") echo "Bengals" ;;
        "cleveland browns"|"browns") echo "Browns" ;;
        # Soccer - EPL
        "brighton & hove albion"|"brighton") echo "Brighton" ;;
        "crystal palace") echo "Crystal.Palace" ;;
        "leeds united"|"leeds") echo "Leeds.United" ;;
        "nottingham forest") echo "Nottingham.Forest" ;;
        "manchester united"|"man united") echo "Manchester.United" ;;
        "manchester city"|"man city") echo "Manchester.City" ;;
        "liverpool") echo "Liverpool" ;;
        "chelsea") echo "Chelsea" ;;
        "arsenal") echo "Arsenal" ;;
        "tottenham hotspur"|"tottenham"|"spurs") echo "Tottenham" ;;
        "aston villa") echo "Aston.Villa" ;;
        "newcastle united"|"newcastle") echo "Newcastle" ;;
        "west ham united"|"west ham") echo "West.Ham" ;;
        "everton") echo "Everton" ;;
        "wolverhampton"|"wolves") echo "Wolves" ;;
        "bournemouth") echo "Bournemouth" ;;
        "fulham") echo "Fulham" ;;
        "brentford") echo "Brentford" ;;
        "ipswich town"|"ipswich") echo "Ipswich" ;;
        "leicester city"|"leicester") echo "Leicester" ;;
        "southampton") echo "Southampton" ;;
        "sunderland") echo "Sunderland" ;;
        # Soccer - Serie A
        "bologna") echo "Bologna" ;;
        "ac milan"|"milan") echo "AC.Milan" ;;
        "juventus"|"juve") echo "Juventus" ;;
        "inter milan"|"inter"|"internazionale") echo "Inter" ;;
        "as roma"|"roma") echo "Roma" ;;
        "napoli"|"ssc napoli") echo "Napoli" ;;
        "lazio"|"ss lazio") echo "Lazio" ;;
        "atalanta") echo "Atalanta" ;;
        "fiorentina") echo "Fiorentina" ;;
        # Fallback: title-case, dots for spaces
        *) echo "$name" | sed 's/[[:space:]]\+/./g; s/.*/\L&/; s/\b./\U&/g' ;;
    esac
}

# ── Non-game content patterns ─────────────────────────────────────────────────

is_unsorted() {
    local text="$1"
    echo "$text" | grep -iqE "(Postgame Recap|Pregame|Pre-Game|All Access|First Take|G League|SportsCenter|Halftime|Post Game)" && return 0
    return 1
}

# ── NFO Parsing (Jellyfin EPG Metadata) ────────────────────────────────────────
# Jellyfin creates .nfo files alongside recordings with rich EPG data:
#   <title>Boston Celtics at Chicago Bulls</title>
#   <plot>Boston Celtics @ Chicago Bulls | United Center, Chicago, IL</plot>
#   <genre>Basketball</genre>
# This is often more detailed than the filename.

parse_nfo_field() {
    local nfo_file="$1"
    local field="$2"
    # Extract field content from XML (simple grep, no XML parser needed)
    grep -oP "(?<=<${field}>).*?(?=</${field}>)" "$nfo_file" 2>/dev/null | head -1
}

find_companion_nfo() {
    local video_file="$1"
    local dir stem nfo_path
    dir=$(dirname "$video_file")
    stem=$(basename "$video_file")
    stem="${stem%.*}"

    # Try exact match
    nfo_path="${dir}/${stem}.nfo"
    [[ -f "$nfo_path" ]] && echo "$nfo_path" && return

    # Try without .work suffix
    stem=$(echo "$stem" | sed 's/\.work$//')
    nfo_path="${dir}/${stem}.nfo"
    [[ -f "$nfo_path" ]] && echo "$nfo_path" && return

    # Try in parent directory (Jellyfin sometimes nests)
    nfo_path="$(dirname "$dir")/${stem}.nfo"
    [[ -f "$nfo_path" ]] && echo "$nfo_path" && return
}

extract_teams_from_text() {
    # Extract "Team1 at/vs/@ Team2" from a text string
    local text="$1"
    if [[ "$text" =~ ^(.+)[[:space:]]+(at|vs\.?|@)[[:space:]]+(.+)$ ]]; then
        local away="${BASH_REMATCH[1]}"
        local home="${BASH_REMATCH[3]}"
        # Clean up: remove venue info after | or ,
        home=$(echo "$home" | sed 's/[|,].*//; s/[[:space:]]*$//')
        away=$(echo "$away" | sed 's/^The //i; s/[[:space:]]*$//')
        echo "${away}|${home}"
        return 0
    fi
    return 1
}

detect_league_from_genre() {
    local genre="$1"
    local genre_lower
    genre_lower=$(echo "$genre" | tr '[:upper:]' '[:lower:]')
    case "$genre_lower" in
        *basketball*) echo "NBA|Basketball.NBA|year-year" ;;
        *baseball*)   echo "MLB|Baseball.MLB|year" ;;
        *football*)   echo "NFL|Football.NFL|year" ;;
        *hockey*)     echo "NHL|Hockey.NHL|year-year" ;;
        *soccer*)     echo "EPL|Soccer.EPL|year-year" ;;
        *)            return 1 ;;
    esac
}

# ── NFO Generation ─────────────────────────────────────────────────────────────

generate_nfo() {
    local title="$1"
    local aired="$2"
    local genre="$3"
    local output="$4"
    local plot="${5:-}"

    cat > "$output" << NFOEOF
<?xml version="1.0" encoding="utf-8" standalone="yes"?>
<episodedetails>
  <title>${title}</title>
  <aired>${aired}</aired>
  <dateadded>$(date '+%Y-%m-%d %H:%M:%S')</dateadded>
  <plot>${plot}</plot>
  <genre>Sports</genre>
  <genre>${genre}</genre>
  <studio />
</episodedetails>
NFOEOF
}

# ── Main Logic ─────────────────────────────────────────────────────────────────

main() {
    local input="${1:?Usage: sports-rename.sh <video_file> [original_dvr_filename]}"
    local original="${2:-$input}"

    if [[ ! -f "$input" ]]; then
        log "ERROR: Input file not found: $input"
        exit 1
    fi

    log "Processing: $input"
    [[ "$original" != "$input" ]] && log "  Original DVR name: $(basename "$original")"

    # Extract info from the filename (use original DVR name for metadata)
    local basename_orig
    basename_orig=$(basename "$original")
    # Strip extension and .work suffix
    local stem="${basename_orig%.*}"
    stem=$(echo "$stem" | sed 's/\.work$//')

    # Extract timestamp: YYYY_MM_DD_HH_MM_SS
    local ts_match
    ts_match=$(echo "$stem" | grep -oE '[0-9]{4}_[0-9]{2}_[0-9]{2}_[0-9]{2}_[0-9]{2}_[0-9]{2}' | head -1)
    if [[ -z "$ts_match" ]]; then
        log "ERROR: Cannot extract timestamp from filename: $basename_orig"
        log "  File will be left in place."
        exit 1
    fi

    local event_date
    event_date=$(echo "$ts_match" | sed 's/_/-/g' | cut -c1-10)
    local event_time
    event_time=$(echo "$ts_match" | cut -d_ -f4-5 | tr -d '_')  # HHMM

    # Split into before-timestamp and after-timestamp
    local before_ts after_ts
    before_ts=$(echo "$stem" | sed "s/${ts_match}.*//; s/[[:space:]]*-[[:space:]]*$//; s/^[[:space:]]*//; s/[[:space:]]*$//")
    after_ts=$(echo "$stem" | sed "s/.*${ts_match}[[:space:]]*-*[[:space:]]*//" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')

    # Clean up "Live  " prefix and collapse spaces
    before_ts=$(echo "$before_ts" | sed 's/^Live[[:space:]]*//' | sed 's/[[:space:]]\{2,\}/ /g' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')

    log "  Date: $event_date | Before: '$before_ts' | After: '$after_ts'"

    # ── Read companion NFO for richer EPG metadata ──
    local nfo_title="" nfo_plot="" nfo_genre="" nfo_file=""
    nfo_file=$(find_companion_nfo "$original")
    if [[ -z "$nfo_file" ]]; then
        # Also try the working file path (may differ after remux)
        nfo_file=$(find_companion_nfo "$input")
    fi
    if [[ -n "$nfo_file" && -f "$nfo_file" ]]; then
        nfo_title=$(parse_nfo_field "$nfo_file" "title")
        nfo_plot=$(parse_nfo_field "$nfo_file" "plot")
        nfo_genre=$(parse_nfo_field "$nfo_file" "genre")
        log "  NFO: title='$nfo_title' | genre='$nfo_genre'"
        [[ -n "$nfo_plot" ]] && log "  NFO plot: $nfo_plot"
    fi

    # Check for unsorted/non-game content
    if is_unsorted "$before_ts $after_ts $nfo_title"; then
        local clean_name
        clean_name=$(sanitize "$before_ts")
        local ext="${input##*.}"
        local res_tag
        res_tag=$(get_resolution_tag "$input")
        local dest_name="${clean_name}.${event_date}"
        [[ -n "$res_tag" ]] && dest_name="${dest_name}.${res_tag}"
        local dest="${SPORTS_ROOT}/Unsorted/${dest_name}.${ext}"
        mkdir -p "${SPORTS_ROOT}/Unsorted"
        log "  → Unsorted: $dest"
        mv "$input" "$dest"
        return 0
    fi

    # Detect league
    local league_match abbrev folder season_type
    league_match=$(lookup_league "$before_ts" 2>/dev/null) || league_match=""

    if [[ -z "$league_match" ]]; then
        # Try the full text
        league_match=$(lookup_league "$before_ts $after_ts" 2>/dev/null) || league_match=""
    fi

    if [[ -z "$league_match" ]]; then
        log "WARNING: No league match for '$before_ts'. Leaving file in place."
        log "  Add a pattern to sports-leagues.conf for this content."
        exit 0
    fi

    IFS='|' read -r abbrev folder season_type <<< "$league_match"
    log "  League: $abbrev ($folder, $season_type)"

    # Extract teams from after-timestamp
    local away_team="" home_team="" event_desc="" qualifier=""

    # Strip trailing number suffix (e.g., "- 1")
    if [[ "$after_ts" =~ ^(.*)\ -\ ([0-9]+)$ ]]; then
        qualifier="${BASH_REMATCH[2]}"
        after_ts="${BASH_REMATCH[1]}"
    fi

    # Try "Team1 at/vs Team2" in after_ts
    if [[ "$after_ts" =~ ^(.+)[[:space:]]+(at|vs\.?|@)[[:space:]]+(.+)$ ]]; then
        away_team=$(short_team "${BASH_REMATCH[1]}")
        home_team=$(short_team "${BASH_REMATCH[3]}")
    fi

    # If no teams from after_ts, try extracting from before_ts
    if [[ -z "$away_team" && -z "$home_team" ]]; then
        # Strip league prefix from before_ts and look for teams
        local stripped
        stripped=$(echo "$before_ts" | sed -E 's/^(EPL|Serie A|Bundesliga|La Liga|MLS|UFC|WWE|AEW|Boxing|NASCAR|Formula 1|NFL Football|NBA Basketball|College Basketball|College Hockey|MLB Baseball|NHL Hockey|Concacaf Champions Cup|Womens? College Basketball|Womens? College Hockey)[[:space:]]*//')
        if [[ "$stripped" =~ ^(.+)[[:space:]]+(vs\.?|at|@)[[:space:]]+(.+)$ ]]; then
            away_team=$(short_team "${BASH_REMATCH[1]}")
            home_team=$(short_team "${BASH_REMATCH[3]}")
        fi
    fi

    # If still no teams, try the whole before_ts
    if [[ -z "$away_team" && -z "$home_team" ]]; then
        if [[ "$before_ts" =~ ^(.+)[[:space:]]+(vs\.?|at|@)[[:space:]]+(.+)$ ]]; then
            away_team=$(short_team "${BASH_REMATCH[1]}")
            home_team=$(short_team "${BASH_REMATCH[3]}")
        fi
    fi

    # Strip short location/channel tags from after_ts if no teams found there
    if [[ -z "$away_team" && -n "$after_ts" ]]; then
        # Only use after_ts as event description if it's meaningful
        if [[ ${#after_ts} -gt 15 ]] && ! echo "$after_ts" | grep -qiE "^[A-Za-z]+$"; then
            event_desc=$(sanitize "$after_ts")
        fi
    fi

    # ── NFO-based team extraction (when filename is generic) ──
    # If we still don't have teams, try the NFO <title> and <plot> fields
    if [[ -z "$away_team" && -z "$home_team" ]]; then
        # Try NFO <title> first (usually cleanest: "Boston Celtics at Chicago Bulls")
        if [[ -n "$nfo_title" ]]; then
            local nfo_teams
            nfo_teams=$(extract_teams_from_text "$nfo_title") || true
            if [[ -n "$nfo_teams" ]]; then
                IFS='|' read -r away_raw home_raw <<< "$nfo_teams"
                away_team=$(short_team "$away_raw")
                home_team=$(short_team "$home_raw")
                log "  Teams from NFO title: $away_team vs $home_team"
            fi
        fi

        # Try NFO <plot> if title didn't have teams
        # Plot often has natural language: "The Boston Celtics visit the New York Knicks at MSG"
        # or shorthand: "Boston Celtics @ Chicago Bulls | United Center, Chicago, IL"
        if [[ -z "$away_team" && -n "$nfo_plot" ]]; then
            # First try "The X visit/host/face the Y" (natural language, must come before "at" check)
            if [[ "$nfo_plot" =~ [Tt]he[[:space:]]+(.+)[[:space:]]+(visit|host|face|take\ on|play)[[:space:]]+(the[[:space:]]+)?(.+) ]]; then
                local team_a="${BASH_REMATCH[1]}"
                local verb="${BASH_REMATCH[2]}"
                local team_b="${BASH_REMATCH[4]}"
                # Strip rankings like "No. 11 " or "#14 "
                team_a=$(echo "$team_a" | sed -E 's/^(No\.[[:space:]]*)?[0-9]+[[:space:]]+//')
                team_b=$(echo "$team_b" | sed -E 's/^(No\.[[:space:]]*)?[0-9]+[[:space:]]+//')
                # Strip venue/location suffixes
                team_b=$(echo "$team_b" | sed -E 's/[[:space:]]+(at|in|from)[[:space:]]+.*//i; s/[[:space:]]*[|,.].*//; s/[[:space:]]*$//')
                if [[ "$verb" == "visit" ]]; then
                    away_team=$(short_team "$team_a")
                    home_team=$(short_team "$team_b")
                else
                    # "host", "face", "take on", "play" = team_a is home
                    away_team=$(short_team "$team_b")
                    home_team=$(short_team "$team_a")
                fi
                log "  Teams from NFO plot ($verb): $away_team vs $home_team"
            else
                # Try shorthand "Team @ Team | Venue" pattern
                local plot_teams
                plot_teams=$(extract_teams_from_text "$nfo_plot") || true
                if [[ -n "$plot_teams" ]]; then
                    IFS='|' read -r away_raw home_raw <<< "$plot_teams"
                    away_team=$(short_team "$away_raw")
                    home_team=$(short_team "$home_raw")
                    log "  Teams from NFO plot: $away_team vs $home_team"
                fi
            fi
        fi

        # Use NFO <genre> to help detect league if still unknown
        if [[ -z "$league_match" && -n "$nfo_genre" ]]; then
            league_match=$(detect_league_from_genre "$nfo_genre") || true
            if [[ -n "$league_match" ]]; then
                IFS='|' read -r abbrev folder season_type <<< "$league_match"
                log "  League from NFO genre: $abbrev ($folder)"
            fi
        fi
    fi

    # ── NFO plot as event description for non-matchup events ──
    if [[ -z "$away_team" && -z "$event_desc" && -n "$nfo_plot" ]]; then
        # Use the plot as event description (e.g., "American League Wild Card, Game 2")
        local clean_plot
        clean_plot=$(echo "$nfo_plot" | sed 's/[|,].*//; s/\.$//; s/[[:space:]]*$//')
        if [[ ${#clean_plot} -lt 60 && ${#clean_plot} -gt 3 ]]; then
            event_desc=$(sanitize "$clean_plot")
            log "  Event from NFO plot: $event_desc"
        fi
    fi

    # Special event handling
    if echo "$before_ts $after_ts $nfo_title" | grep -qi "home run derby"; then
        event_desc="Home.Run.Derby"
        away_team=""
        home_team=""
    fi

    # Compute season
    local season
    season=$(compute_season "$event_date" "$season_type" "$folder")

    # Get resolution
    local res_tag
    res_tag=$(get_resolution_tag "$input")

    # Build filename
    local ext="${input##*.}"
    local parts=("$abbrev" "$event_date")
    if [[ -n "$away_team" && -n "$home_team" ]]; then
        parts+=("${away_team}.vs.${home_team}")
    elif [[ -n "$event_desc" ]]; then
        parts+=("$event_desc")
    else
        # No teams, no description -- use time as disambiguator
        parts+=("$event_time")
    fi
    [[ -n "$qualifier" ]] && parts+=("$qualifier")
    [[ -n "$res_tag" ]] && parts+=("$res_tag")

    local filename
    filename=$(IFS='.'; echo "${parts[*]}")
    filename="${filename}.${ext}"

    local dest_dir="${SPORTS_ROOT}/${folder}/${season}"
    local dest="${dest_dir}/${filename}"

    # Handle collision
    if [[ -f "$dest" ]]; then
        local base="${filename%.*}"
        for i in $(seq 2 9); do
            local alt="${dest_dir}/${base}.${i}.${ext}"
            if [[ ! -f "$alt" ]]; then
                dest="$alt"
                break
            fi
        done
    fi

    # Create directory and move
    mkdir -p "$dest_dir"
    log "  → $dest"
    mv "$input" "$dest"

    # Move EDL sidecar if it exists
    local edl_source="${input%.*}.edl"
    if [[ -f "$edl_source" ]]; then
        local edl_dest="${dest%.*}.edl"
        mv "$edl_source" "$edl_dest"
        log "  EDL: $(basename "$edl_dest")"
    fi

    # Generate NFO
    local nfo_dest="${dest%.*}.nfo"
    local title_display=""
    if [[ -n "$away_team" && -n "$home_team" ]]; then
        title_display="${away_team} vs ${home_team}"
    elif [[ -n "$event_desc" ]]; then
        title_display=$(echo "$event_desc" | tr '.' ' ')
    else
        title_display="$abbrev $event_date"
    fi
    title_display=$(echo "$title_display" | sed 's/\./ /g')

    # Determine genre for NFO
    local genre="Sports"
    case "$folder" in
        *Baseball*) genre="Baseball" ;;
        *Basketball*) genre="Basketball" ;;
        *Football*) genre="Football" ;;
        *Soccer*|*EPL*|*Serie*|*Liga*|*MLS*|*Champions*|*CONCACAF*) genre="Soccer" ;;
        *Hockey*) genre="Hockey" ;;
        *Combat*|*Boxing*) genre="Combat Sports" ;;
        *Motorsport*) genre="Motorsports" ;;
        *Wrestling*) genre="Wrestling" ;;
        *Tennis*) genre="Tennis" ;;
        *Golf*) genre="Golf" ;;
    esac

    # Preserve original plot from Jellyfin EPG if available
    local plot_text="${nfo_plot:-}"
    generate_nfo "$title_display" "$event_date" "$genre" "$nfo_dest" "$plot_text"
    log "  NFO: $(basename "$nfo_dest")"

    # Copy any Jellyfin-generated metadata from the original recording location
    local orig_dir orig_stem
    orig_dir=$(dirname "$original")
    orig_stem=$(basename "$original" ".${original##*.}")
    # Thumbnail
    for thumb in "${orig_dir}/${orig_stem}-thumb.jpg" "${orig_dir}/${orig_stem}.jpg"; do
        if [[ -f "$thumb" ]]; then
            cp "$thumb" "${dest%.*}-thumb.jpg"
            log "  THUMB: copied from original"
            break
        fi
    done

    # Trigger Jellyfin library scan if API key is configured
    if [[ -n "$JELLYFIN_API_KEY" ]]; then
        curl -sf -X POST "${JELLYFIN_URL}/Library/Refresh" \
            -H "X-Emby-Token: ${JELLYFIN_API_KEY}" >/dev/null 2>&1 || true
        log "  Jellyfin library scan triggered"
    fi

    log "  Done."
}

main "$@"
