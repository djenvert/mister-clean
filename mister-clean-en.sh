#!/bin/zsh
# =============================================================================
# mister-clean-en.sh — macOS disk audit: Spotlight, caches, old AI models,
#                      large folders, protection of active projects, and a
#                      cleanup plan (printed with --dry-run, executed after
#                      confirmation otherwise).
#
# Usage:
#   ./mister-clean-en.sh --dry-run         # audit + plan, nothing deleted
#   ./mister-clean-en.sh                   # audit + plan + confirmation + execution
#
# Options:
#   --dry-run          Execute nothing, only print the plan.
#   --yes              Run SAFE actions without asking (CAUTION actions are
#                      still asked one by one, never auto-accepted).
#   --days N           A cache untouched for N days counts as "unused" (30).
#   --model-days N     A model untouched for N days counts as "old" (90).
#   --active-days N    A project modified within N days counts as "active" (30).
#   --top N            Number of rows in the rankings (20).
#   --fast             Skip slow steps (system log, deep du).
#   --skip-spotlight   Skip the Spotlight audit.
#   -h, --help         This help.
#
# Verdicts:
#   SAFE      Regenerable cache, no open file, no active project involved
#             → deleted in one batch after the global confirmation.
#   CAUTION   Recoverable but costly (models, snapshots, recent caches…)
#             → asked item by item.
#   MANUAL    Never touched by the script (Xcode archives, iOS backups,
#             Downloads…) → only listed.
# =============================================================================

emulate -L zsh
setopt null_glob pipe_fail no_nomatch
set -u

VERSION="1.0.0"

# ----------------------------------------------------------------------------
# Options
# ----------------------------------------------------------------------------
DRY_RUN=0
ASSUME_YES=0
CACHE_DAYS=30
MODEL_DAYS=90
ACTIVE_DAYS=30
TOP=20
FAST=0
SKIP_SPOTLIGHT=0

usage() { sed -n '2,33p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }

while (( $# > 0 )); do
  case "$1" in
    --dry-run)        DRY_RUN=1 ;;
    --yes|-y)         ASSUME_YES=1 ;;
    --days)           CACHE_DAYS="$2"; shift ;;
    --model-days)     MODEL_DAYS="$2"; shift ;;
    --active-days)    ACTIVE_DAYS="$2"; shift ;;
    --top)            TOP="$2"; shift ;;
    --fast)           FAST=1 ;;
    --skip-spotlight) SKIP_SPOTLIGHT=1 ;;
    -h|--help)        usage ;;
    *) print -u2 "Unknown option: $1 (see --help)"; exit 2 ;;
  esac
  shift
done

if [[ "$(uname -s)" != "Darwin" ]]; then
  print -u2 "This script is designed for macOS only."; exit 1
fi

# ----------------------------------------------------------------------------
# Output, log file, colors
# ----------------------------------------------------------------------------
LOG_DIR="$HOME/Library/Logs/mister-clean"
mkdir -p "$LOG_DIR"
RUN_ID="$(date +%Y%m%d-%H%M%S)"
LOG_FILE="$LOG_DIR/run-$RUN_ID.log"
TMP="$(mktemp -d -t mister-clean)"
trap 'rm -rf "$TMP"' EXIT

if [[ -t 1 ]]; then
  C_RESET=$'\e[0m'; C_BOLD=$'\e[1m'; C_DIM=$'\e[2m'
  C_RED=$'\e[31m'; C_GREEN=$'\e[32m'; C_YELLOW=$'\e[33m'; C_BLUE=$'\e[34m'; C_CYAN=$'\e[36m'
else
  C_RESET=""; C_BOLD=""; C_DIM=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_CYAN=""
fi

# Everything printed is also logged (without color codes).
exec > >(tee >(sed 's/\x1b\[[0-9;]*m//g' >> "$LOG_FILE")) 2>&1

say()    { print -r -- "$@"; }
h1()     { print; print -r -- "${C_BOLD}${C_BLUE}━━━ $* ━━━${C_RESET}"; }
h2()     { print; print -r -- "${C_BOLD}$*${C_RESET}"; }
ok()     { print -r -- "  ${C_GREEN}✔${C_RESET} $*"; }
warn()   { print -r -- "  ${C_YELLOW}▲${C_RESET} $*"; }
bad()    { print -r -- "  ${C_RED}✘${C_RESET} $*"; }
info()   { print -r -- "  ${C_DIM}·${C_RESET} $*"; }
dim()    { print -r -- "${C_DIM}$*${C_RESET}"; }

# ----------------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------------
human() {  # KiB -> human readable
  local kb=${1:-0}
  if (( kb >= 1073741824 )); then printf "%.1f TiB" $(( kb / 1073741824.0 ))
  elif (( kb >= 1048576 ));  then printf "%.1f GiB" $(( kb / 1048576.0 ))
  elif (( kb >= 1024 ));     then printf "%.0f MiB" $(( kb / 1024.0 ))
  else printf "%d KiB" $kb; fi
}

du_kb() {  # size of a path in KiB (0 if missing)
  [[ -e "$1" ]] || { print 0; return; }
  local r
  r=$(du -sk "$1" 2>/dev/null | cut -f1)
  print -- "${r:-0}"
}

# Days since the most recent modification (limited depth).
newest_age_days() {
  local p="$1" now newest
  now=$(date +%s)
  newest=$( { stat -f %m "$p"; find "$p" -maxdepth 3 -print0 2>/dev/null | xargs -0 stat -f %m 2>/dev/null; } | sort -rn | head -1 )
  [[ -z "$newest" ]] && { print 9999; return; }
  print -- $(( (now - newest) / 86400 ))
}

is_recent() {  # 0 if any file was modified less than N days ago
  local p="$1" days="$2"
  [[ -n "$(find "$p" -type f -mtime -"$days" -print -quit 2>/dev/null)" ]]
}

run_with_timeout() {  # run_with_timeout SECONDS cmd...
  local s="$1"; shift
  perl -e 'alarm shift; exec @ARGV' "$s" "$@"
}

have() { command -v "$1" >/dev/null 2>&1; }
is_running() { pgrep -x "$1" >/dev/null 2>&1; }

# ----------------------------------------------------------------------------
# Registry of cleanup candidates
# ----------------------------------------------------------------------------
typeset -a CAND_CAT CAND_LABEL CAND_PATH CAND_KB CAND_AGE CAND_VERDICT CAND_REASON CAND_ACTION
typeset -a OPEN_FILES ACTIVE_PROJECTS

# add_candidate CAT LABEL PATH KB AGE VERDICT REASON ACTION
add_candidate() {
  CAND_CAT+=("$1"); CAND_LABEL+=("$2"); CAND_PATH+=("$3"); CAND_KB+=("$4")
  CAND_AGE+=("$5"); CAND_VERDICT+=("$6"); CAND_REASON+=("$7"); CAND_ACTION+=("$8")
}

# Is a path "touched" by an active project or an open file?
# Prints the reason, empty if none.
conflict_reason() {
  local p="$1" proj f
  for proj in "${ACTIVE_PROJECTS[@]}"; do
    [[ "$p" == "$proj" || "$p" == "$proj"/* ]] && { print -- "inside active project $proj"; return; }
  done
  if [[ -s "$TMP/open_files" ]] && grep -q -F -- "$p/" "$TMP/open_files"; then
    f=$(grep -F -- "$p/" "$TMP/open_files" | head -1)
    print -- "file open by a process: ${f#$p/}"
    return
  fi
  print -- ""
}

# Decides SAFE / CAUTION from age and conflicts.
# verdict_for PATH DAYS_THRESHOLD "reason if CAUTION is forced"
verdict_for() {
  local p="$1" days="$2" forced="${3:-}" c
  c=$(conflict_reason "$p")
  if [[ -n "$c" ]]; then print -- "CAUTION|$c"; return; fi
  if [[ -n "$forced" ]]; then print -- "CAUTION|$forced"; return; fi
  if is_recent "$p" "$days"; then
    print -- "CAUTION|modified less than $days d ago (still in use, will be regenerated)"
  else
    print -- "SAFE|untouched for ≥ $days d, regenerable"
  fi
}

# ----------------------------------------------------------------------------
# Header
# ----------------------------------------------------------------------------
print -r -- "${C_BOLD}${C_CYAN}mister-clean v$VERSION${C_RESET} — $(date '+%Y-%m-%d %H:%M')  $( ((DRY_RUN)) && print -- '[DRY-RUN]' )"
dim "macOS $(sw_vers -productVersion) · $(uname -m) · log: $LOG_FILE"
dim "Thresholds: unused cache ≥ ${CACHE_DAYS} d · old model ≥ ${MODEL_DAYS} d · active project ≤ ${ACTIVE_DAYS} d"

h1 "0. Disk state"
DATA_VOL="/System/Volumes/Data"
[[ -d "$DATA_VOL" ]] || DATA_VOL="/"
DF_LINE=$(df -k "$DATA_VOL" | tail -1)
DISK_TOTAL_KB=$(print -- "$DF_LINE" | awk '{print $2}')
DISK_USED_KB=$(print -- "$DF_LINE" | awk '{print $3}')
DISK_FREE_KB=$(print -- "$DF_LINE" | awk '{print $4}')
info "Data volume: $(human $DISK_USED_KB) used / $(human $DISK_TOTAL_KB) · free: $(human $DISK_FREE_KB)"
PURGEABLE=$(diskutil info "$DATA_VOL" 2>/dev/null | awk -F: '/Purgeable/ {gsub(/^ +/,"",$2); print $2}' | head -1)
[[ -n "$PURGEABLE" ]] && info "Purgeable space (macOS can free it by itself): $PURGEABLE"
SNAP_COUNT=$(tmutil listlocalsnapshots / 2>/dev/null | grep -c 'com.apple.TimeMachine')
info "Local Time Machine snapshots: $SNAP_COUNT"

# Full Disk Access (TCC): without it, ~/Documents, ~/Desktop and mdfind results
# are hidden from this terminal → the Spotlight cross-checks would be skewed.
TCC_OK=1
if ! ls "$HOME/Desktop" >/dev/null 2>&1 && [[ -d "$HOME/Desktop" ]]; then TCC_OK=0; fi
if (( TCC_OK )); then ok "Full Disk Access: OK for this terminal."
else
  warn "This terminal does NOT have Full Disk Access (System Settings > Privacy & Security)."
  warn "The Spotlight sample/probe tests will be marked INCONCLUSIVE, and some caches will not be visible."
fi

# ----------------------------------------------------------------------------
# 1. Active projects & open files  (the safety net)
# ----------------------------------------------------------------------------
h1 "1. Active projects and open files (safety net)"

info "Git repositories modified within ${ACTIVE_DAYS} d…"
while IFS= read -r gitdir; do
  proj="${gitdir:h}"
  if [[ -n "$(find "$proj" -maxdepth 4 -type f -mtime -"$ACTIVE_DAYS" \
        -not -path '*/node_modules/*' -not -path '*/.git/*' -print -quit 2>/dev/null)" ]]; then
    ACTIVE_PROJECTS+=("$proj")
  fi
done < <(find "$HOME" -maxdepth 5 -name .git -type d \
          -not -path "$HOME/Library/*" -not -path "$HOME/.Trash/*" \
          -not -path '*/node_modules/*' -not -path "$HOME/.*/*" 2>/dev/null)

info "Files open by your processes (lsof)…"
lsof -n -u "$USER" -F n 2>/dev/null | sed -n 's/^n//p' | grep "^$HOME/" | sort -u > "$TMP/open_files" || true
# Working directories of shells/editors count as active projects too
lsof -n -u "$USER" -a -d cwd -F n 2>/dev/null | sed -n 's/^n//p' | grep "^$HOME/" | grep -v "^$HOME/Library" | sort -u > "$TMP/cwds" || true
while IFS= read -r d; do
  [[ "$d" == "$HOME" ]] && continue
  # climb up to the git repository if there is one
  r="$d"; while [[ "$r" != "$HOME" && "$r" != "/" && ! -d "$r/.git" ]]; do r="${r:h}"; done
  [[ -d "$r/.git" ]] && d="$r"
  (( ${ACTIVE_PROJECTS[(Ie)$d]} )) || ACTIVE_PROJECTS+=("$d")
done < "$TMP/cwds"

if (( ${#ACTIVE_PROJECTS} )); then
  ok "${#ACTIVE_PROJECTS} project(s) considered active — nothing will be touched there:"
  for p in "${ACTIVE_PROJECTS[@]}"; do info "  ${p/#$HOME/~}"; done
else
  ok "No active project detected."
fi
info "$(wc -l < "$TMP/open_files" | tr -d ' ') open files under ~ (any cache containing one of them is downgraded to CAUTION)."

typeset -a RUNNING_APPS
for app in Xcode ollama "Docker" "Code" "Cursor" "Google Chrome" Safari Arc Firefox Slack Spotify "LM Studio"; do
  is_running "$app" && RUNNING_APPS+=("$app")
done
(( ${#RUNNING_APPS} )) && info "Running apps: ${(j:, :)RUNNING_APPS}"

# ----------------------------------------------------------------------------
# 2. Spotlight — cross-verification
# ----------------------------------------------------------------------------
SPOT_SUSPECT=0
typeset -a SPOT_FINDINGS
if (( ! SKIP_SPOTLIGHT )); then
  h1 "2. Spotlight — index cross-verification"

  h2 "2a. Indexing state per volume (mdutil)"
  typeset -a VOLS; VOLS=("/")
  while IFS= read -r v; do VOLS+=("$v"); done < <(mount | grep -E '^/dev/.* on /Volumes/' | grep -v nobrowse | sed -E 's#^/dev/[^ ]+ on (/Volumes/.*) \(.*$#\1#')
  for v in "${VOLS[@]}"; do
    st=$(mdutil -s "$v" 2>&1 | tail -1 | sed 's/^[[:space:]]*//')
    case "$st" in
      *"Indexing enabled"*) ok "$v: $st" ;;
      *"disabled"*)         warn "$v: $st (volume excluded from Spotlight — no index to clean)" ;;
      *"could not resolve"*) warn "$v: not reachable from this terminal ($st)" ;;
      *) bad "$v: $st"; SPOT_FINDINGS+=("mdutil reports an abnormal state on $v: $st"); (( SPOT_SUSPECT++ )) ;;
    esac
  done

  h2 "2b. Index size vs data size"
  SPOT_IDX="/System/Volumes/Data/.Spotlight-V100"
  SPOT_IDX_KB=0
  if sudo -n true 2>/dev/null; then
    SPOT_IDX_KB=$(sudo -n du -sk "$SPOT_IDX" 2>/dev/null | cut -f1); SPOT_IDX_KB=${SPOT_IDX_KB:-0}
  else
    SPOT_IDX_KB=$(du_kb "$SPOT_IDX")
  fi
  USER_IDX_KB=$(du_kb "$HOME/Library/Metadata/CoreSpotlight")
  if (( SPOT_IDX_KB > 0 )); then
    ratio=$(( SPOT_IDX_KB * 100.0 / DISK_USED_KB ))
    info "System index: $(human $SPOT_IDX_KB) ($(printf '%.2f' $ratio) % of data). Normal: 0.5 – 3 %."
    if (( ratio > 8 )); then
      bad "Abnormally high ratio → bloated/stale index likely."
      SPOT_FINDINGS+=("system index = $(printf '%.1f' $ratio) % of data (expected < 3 %)"); (( SPOT_SUSPECT++ ))
    fi
  else
    warn "System index not measurable without sudo (Full Disk Access required). Run 'sudo -v' first if needed."
  fi
  info "User index (CoreSpotlight): $(human $USER_IDX_KB)"

  h2 "2c. Cross-check #1 — sample of real files vs index"
  SAMPLE_DIR=""
  for cand in "$HOME/Documents" "$HOME/Desktop" "$HOME/Pictures" "$HOME/Movies" "$HOME/Music" "$HOME"; do
    [[ -d "$cand" ]] && ls "$cand" >/dev/null 2>&1 && [[ -n "$(find "$cand" -maxdepth 3 -type f -not -path '*/.*' -print -quit 2>/dev/null)" ]] && { SAMPLE_DIR="$cand"; break; }
  done
  [[ -z "$SAMPLE_DIR" ]] && SAMPLE_DIR="$HOME"
  info "Sampled folder: ${SAMPLE_DIR/#$HOME/~}"
  # Hidden files and the inside of packages (.app, .pages…) are skipped: Spotlight indexes a package as one item.
  find "$SAMPLE_DIR" -type f -not -path '*/.*' \
    -not -path '*.app/*' -not -path '*.pages/*' -not -path '*.numbers/*' -not -path '*.key/*' \
    -not -path '*.photoslibrary/*' -not -path '*.bundle/*' -not -path '*.framework/*' \
    -not -path '*/node_modules/*' -mtime +1 2>/dev/null | head -5000 | sort -R | head -40 > "$TMP/sample"
  n=$(wc -l < "$TMP/sample" | tr -d ' '); miss=0
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    b="${f:t}"
    if ! mdfind -onlyin "${f:h}" -name "$b" 2>/dev/null | grep -qxF -- "$f"; then
      (( miss++ )); (( miss <= 5 )) && info "  missing from index: ${f/#$HOME/~}"
    fi
  done < "$TMP/sample"
  if (( ! TCC_OK )); then
    warn "INCONCLUSIVE: $miss / $n missing, but mdfind is restricted without Full Disk Access. Rerun from Terminal.app with access granted."
  elif (( n == 0 )); then
    warn "No file to sample in $SAMPLE_DIR."
  else
    pct=$(( miss * 100 / n ))
    if (( pct > 20 )); then
      bad "$miss / $n files (${pct} %) exist on disk but are unknown to Spotlight → incomplete/corrupted index."
      SPOT_FINDINGS+=("$miss/$n sampled files missing from the index"); (( SPOT_SUSPECT++ ))
    elif (( pct > 5 )); then
      warn "$miss / $n files missing from the index (${pct} %) — tolerable, but worth watching."
    else
      ok "$miss / $n files missing from the index (${pct} %) — the index reflects the disk."
    fi
  fi

  h2 "2d. Cross-check #2 — live probe (is the daemon still indexing?)"
  PROBE="$HOME/mister-clean-probe-$RUN_ID.txt"
  print -- "mister-clean probe $RUN_ID" > "$PROBE" 2>/dev/null
  found=0
  for i in {1..15}; do
    sleep 1
    if mdfind -name "mister-clean-probe-$RUN_ID" 2>/dev/null | grep -q .; then found=$i; break; fi
  done
  rm -f "$PROBE"
  if (( found )); then ok "New file indexed in ${found} s — mds is working."
  elif (( ! TCC_OK )); then warn "INCONCLUSIVE: probe not visible, but mdfind is restricted for this terminal (see above)."
  else bad "New file still not indexed after 15 s → indexing stalled or broken."
       SPOT_FINDINGS+=("probe not indexed after 15 s"); (( SPOT_SUSPECT++ )); fi

  h2 "2e. Cross-check #3 — system log and mds processes"
  if (( FAST )); then
    info "(--fast) system log skipped."
  else
    run_with_timeout 120 log show --last 2h --style compact \
        --predicate 'process == "mds" OR process == "mds_stores" OR process BEGINSWITH "mdworker"' 2>/dev/null \
      | grep -iE 'corrupt|damaged|invalid index|rebuilding index|reset index|index.*unusable' > "$TMP/mdslog" || true
    errs=$(wc -l < "$TMP/mdslog" | tr -d ' ')
    if (( errs > 0 )); then
      bad "$errs message(s) hinting at index corruption in the last 2 hours:"
      head -3 "$TMP/mdslog" | cut -c1-200 | sed 's/^/      /'
      SPOT_FINDINGS+=("$errs corruption messages in the mds log"); (( SPOT_SUSPECT++ ))
    else ok "No corruption message in the mds log (2 h)."; fi
  fi
  mdcpu=$(ps -Ao %cpu,comm | awk '$2 ~ /mds_stores|mdworker|mds$/ {s+=$1} END {printf "%.0f", s+0}')
  if (( mdcpu > 150 )); then warn "mds/mdworker use ${mdcpu} % CPU: reindexing in progress or stuck in a loop."
  else info "Combined mds/mdworker CPU: ${mdcpu} %"; fi

  h2 "2f. Spotlight verdict"
  if (( SPOT_SUSPECT == 0 && ! TCC_OK )); then
    warn "No sign of corruption on the available tests, but 2 of 3 tests are INCONCLUSIVE without Full Disk Access."
  elif (( SPOT_SUSPECT == 0 )); then
    ok "Index HEALTHY: the ${C_BOLD}3 cross-checks${C_RESET} agree (sample, probe, log). No rebuild needed."
  else
    bad "Index SUSPECT ($SPOT_SUSPECT clue(s)):"
    for f in "${SPOT_FINDINGS[@]}"; do info "  – $f"; done
    add_candidate "Spotlight" "Rebuild the Spotlight index (mdutil -E /)" "$SPOT_IDX" "$SPOT_IDX_KB" "-" \
      "CAUTION" "suspect index; the rebuild wipes the bloated index then reindexes (CPU for 1–3 h)" \
      "sudo:mdutil -E /"
  fi
fi

# ----------------------------------------------------------------------------
# 3. Caches
# ----------------------------------------------------------------------------
h1 "3. Cache scan"

scan_cache_dir() {  # scan_cache_dir CATEGORY ROOT  (each subfolder becomes a candidate)
  local cat="$1" root="$2" d kb age v reason forced
  [[ -d "$root" ]] || return 0
  for d in "$root"/*(N); do
    [[ "${d:t}" == "Homebrew" || "${d:t}" == "pip" ]] && continue   # handled by their own tool (brew cleanup, pip cache purge)
    kb=$(du_kb "$d"); (( kb < 10240 )) && continue   # < 10 MiB: not worth it
    age=$(newest_age_days "$d")
    forced=""
    case "${d:t}" in
      com.apple.*) forced="Apple cache; regenerated but sometimes costly to rebuild (e.g. Photos, iCloud)" ;;
      CloudKit*|com.apple.bird*) forced="tied to iCloud" ;;
    esac
    IFS='|' read -r v reason <<< "$(verdict_for "$d" "$CACHE_DAYS" "$forced")"
    add_candidate "$cat" "${d:t}" "$d" "$kb" "$age" "$v" "$reason" "rm-contents:$d"
  done
}

info "~/Library/Caches…";   scan_cache_dir "App cache" "$HOME/Library/Caches"
info "~/.cache…";           scan_cache_dir "CLI cache" "$HOME/.cache"

# Logs
for logroot in "$HOME/Library/Logs" "/Library/Logs/DiagnosticReports" "$HOME/Library/Logs/DiagnosticReports"; do
  [[ -d "$logroot" ]] || continue
  kb=$(find "$logroot" -type f -mtime +"$CACHE_DAYS" -print0 2>/dev/null | xargs -0 du -sk 2>/dev/null | awk '{s+=$1} END {print s+0}')
  (( kb < 5120 )) && continue
  add_candidate "Logs" "${logroot/#$HOME/~} (files > ${CACHE_DAYS} d)" "$logroot" "$kb" "$CACHE_DAYS+" \
    "SAFE" "old logs, worthless unless a diagnosis is in progress" "rm-old-files:$logroot:$CACHE_DAYS"
done

# Developer tools
h2 "Developer tools"
XC="$HOME/Library/Developer/Xcode"
if [[ -d "$XC/DerivedData" ]]; then
  kb=$(du_kb "$XC/DerivedData"); forced=""; is_running Xcode && forced="Xcode is open: quit it first"
  IFS='|' read -r v reason <<< "$(verdict_for "$XC/DerivedData" "$CACHE_DAYS" "$forced")"
  (( kb > 0 )) && add_candidate "Xcode" "DerivedData (intermediate builds)" "$XC/DerivedData" "$kb" "$(newest_age_days "$XC/DerivedData")" "$v" "$reason" "rm-contents:$XC/DerivedData"
fi
for ds in "$XC"/*DeviceSupport(N); do
  kb=$(du_kb "$ds"); (( kb > 0 )) && add_candidate "Xcode" "${ds:t} (symbols of old OS versions)" "$ds" "$kb" "$(newest_age_days "$ds")" \
    "SAFE" "re-downloaded the next time a device is plugged in" "rm-contents:$ds"
done
[[ -d "$XC/Archives" ]] && { kb=$(du_kb "$XC/Archives"); (( kb > 0 )) && add_candidate "Xcode" "Archives (.xcarchive + dSYM)" "$XC/Archives" "$kb" "$(newest_age_days "$XC/Archives")" \
    "MANUAL" "holds the symbols of shipped releases: sort by hand" "none"; }
CS="$HOME/Library/Developer/CoreSimulator"
if [[ -d "$CS/Caches" ]]; then
  kb=$(du_kb "$CS/Caches")
  IFS='|' read -r v reason <<< "$(verdict_for "$CS/Caches" "$CACHE_DAYS")"
  (( kb > 0 )) && add_candidate "Simulator" "CoreSimulator/Caches" "$CS/Caches" "$kb" "$(newest_age_days "$CS/Caches")" "$v" "$reason" "rm-contents:$CS/Caches"
fi
if [[ -d "$CS/Devices" ]] && have xcrun; then
  kb=$(du_kb "$CS/Devices")
  (( kb > 0 )) && add_candidate "Simulator" "Unavailable simulators (runtime uninstalled)" "$CS/Devices" "$kb" "-" \
    "SAFE" "xcrun simctl delete unavailable only removes orphaned simulators" "cmd:xcrun simctl delete unavailable"
fi

# Package managers
h2 "Package managers"
if have brew; then
  bc=$(brew --cache 2>/dev/null); kb=$(du_kb "$bc")
  (( kb > 0 )) && add_candidate "Homebrew" "download cache + old versions" "$bc" "$kb" "$(newest_age_days "$bc")" \
    "SAFE" "brew cleanup --prune=all -s removes stale bottles and downloads" "cmd:brew cleanup --prune=all -s"
fi
[[ -d "$HOME/.npm/_cacache" ]] && { kb=$(du_kb "$HOME/.npm/_cacache"); (( kb > 0 )) && add_candidate "npm" "npm cache (_cacache)" "$HOME/.npm/_cacache" "$kb" "$(newest_age_days "$HOME/.npm/_cacache")" \
    "SAFE" "re-downloaded on demand" "cmd:npm cache clean --force"; }
if have pnpm; then
  ps_=$(pnpm store path 2>/dev/null); [[ -d "$ps_" ]] && { kb=$(du_kb "$ps_"); (( kb > 0 )) && add_candidate "pnpm" "pnpm store (orphaned packages)" "$ps_" "$kb" "$(newest_age_days "$ps_")" \
    "SAFE" "pnpm store prune only removes unreferenced packages" "cmd:pnpm store prune"; }
fi
if have yarn; then
  yc=$(yarn cache dir 2>/dev/null); [[ -d "$yc" ]] && { kb=$(du_kb "$yc"); (( kb > 10240 )) && add_candidate "yarn" "yarn cache" "$yc" "$kb" "$(newest_age_days "$yc")" \
    "SAFE" "re-downloaded on demand" "cmd:yarn cache clean"; }
fi
have pip3 && { pc=$(pip3 cache dir 2>/dev/null); [[ -d "$pc" && "$pc" != "$HOME/Library/Caches/pip" ]] && { kb=$(du_kb "$pc"); (( kb > 10240 )) && add_candidate "pip" "pip cache" "$pc" "$kb" "$(newest_age_days "$pc")" "SAFE" "re-downloaded on demand" "cmd:pip3 cache purge"; }; }
have uv && { uc=$(uv cache dir 2>/dev/null); [[ -d "$uc" ]] && { kb=$(du_kb "$uc"); (( kb > 10240 )) && add_candidate "uv" "uv cache" "$uc" "$kb" "$(newest_age_days "$uc")" "SAFE" "uv cache prune only removes unused entries" "cmd:uv cache prune"; }; }
[[ -d "$HOME/.cargo/registry" ]] && { kb=$(du_kb "$HOME/.cargo/registry"); (( kb > 10240 )) && add_candidate "cargo" "Rust registry (sources + crates)" "$HOME/.cargo/registry" "$kb" "$(newest_age_days "$HOME/.cargo/registry")" \
    "CAUTION" "re-downloaded on the next build, but slow when offline" "rm-contents:$HOME/.cargo/registry/cache"; }
[[ -d "$HOME/go/pkg/mod" ]] && { kb=$(du_kb "$HOME/go/pkg/mod"); (( kb > 10240 )) && add_candidate "go" "Go module cache" "$HOME/go/pkg/mod" "$kb" "$(newest_age_days "$HOME/go/pkg/mod")" \
    "CAUTION" "re-downloaded on the next build" "cmd:go clean -modcache"; }
if [[ -d "$HOME/.gradle/caches" ]]; then
  kb=$(du_kb "$HOME/.gradle/caches")
  IFS='|' read -r v reason <<< "$(verdict_for "$HOME/.gradle/caches" "$CACHE_DAYS")"
  (( kb > 10240 )) && add_candidate "gradle" "Gradle caches" "$HOME/.gradle/caches" "$kb" "$(newest_age_days "$HOME/.gradle/caches")" "$v" "$reason" "rm-contents:$HOME/.gradle/caches"
fi

# Docker
if have docker && docker info >/dev/null 2>&1; then
  h2 "Docker"
  docker system df 2>/dev/null | sed 's/^/    /'
  rec=$(docker system df --format '{{.Reclaimable}}' 2>/dev/null | head -1)
  add_candidate "Docker" "unused images/containers/volumes" "docker" "0" "-" "CAUTION" "reclaimable: ${rec:-?}; docker system prune (volumes kept)" "cmd:docker system prune -f"
fi

# ----------------------------------------------------------------------------
# 4. Old AI models
# ----------------------------------------------------------------------------
h1 "4. Local AI models"

rel_to_days() {  # "3 weeks ago" -> 21
  local n="$1" u="$2"
  case "$u" in
    second*|minute*|hour*) print 0 ;;
    day*)   print -- $n ;;
    week*)  print -- $(( n * 7 )) ;;
    month*) print -- $(( n * 30 )) ;;
    year*)  print -- $(( n * 365 )) ;;
    *) print 0 ;;
  esac
}

if have ollama; then
  h2 "Ollama"
  LOADED=$(ollama ps 2>/dev/null | awk 'NR>1 {print $1}' | tr '\n' ' ')
  OLL_KB=$(du_kb "$HOME/.ollama/models")
  info "Store: ~/.ollama/models = $(human $OLL_KB)  · loaded: ${LOADED:-none}"
  info "(Ollama does not track last use; age = date of pull / update.)"
  ollama list 2>/dev/null | awk 'NR>1' | while read -r name id sz unit n u rest; do
    [[ -z "$name" ]] && continue
    case "$unit" in GB) kb=$(( sz * 1048576 )) ;; MB) kb=$(( sz * 1024 )) ;; *) kb=0 ;; esac
    kb=${kb%.*}
    if [[ "$n" == "About" || "$n" == "an" || "$n" == "a" ]]; then days=0; else days=$(rel_to_days "$n" "$u"); fi
    if [[ " $LOADED " == *" $name "* ]]; then
      v="CAUTION"; reason="currently loaded in memory"
    elif (( days >= MODEL_DAYS )); then
      v="CAUTION"; reason="pulled ${days} d ago ≥ ${MODEL_DAYS} d; ollama pull $name to get it back"
    else
      v="MANUAL"; reason="recent (${days} d) — kept"
    fi
    add_candidate "Ollama model" "$name" "ollama:$name" "$kb" "$days" "$v" "$reason" "cmd:ollama rm $name"
  done
fi

scan_model_root() {  # scan_model_root LABEL ROOT
  local label="$1" root="$2" d kb age
  [[ -d "$root" ]] || return 0
  h2 "$label"
  for d in "$root"/*(N/); do
    kb=$(du_kb "$d"); (( kb < 51200 )) && continue   # < 50 MiB
    age=$(newest_age_days "$d")
    c=$(conflict_reason "$d")
    if [[ -n "$c" ]]; then v="CAUTION"; reason="$c"
    elif (( age >= MODEL_DAYS )); then v="CAUTION"; reason="untouched for ${age} d ≥ ${MODEL_DAYS} d; re-downloadable"
    else v="MANUAL"; reason="recent (${age} d) — kept"; fi
    add_candidate "$label" "${d:t}" "$d" "$kb" "$age" "$v" "$reason" "rm-path:$d"
  done
}
scan_model_root "Hugging Face model" "$HOME/.cache/huggingface/hub"
scan_model_root "LM Studio model"    "$HOME/.lmstudio/models"
scan_model_root "LM Studio model"    "$HOME/.cache/lm-studio/models"
scan_model_root "Whisper model"      "$HOME/.cache/whisper"
scan_model_root "Torch model"        "$HOME/.cache/torch/hub/checkpoints"

# ----------------------------------------------------------------------------
# 5. Large folders
# ----------------------------------------------------------------------------
h1 "5. Large folders"

# Local Time Machine snapshots
if (( SNAP_COUNT > 0 )); then
  tmutil listlocalsnapshots / 2>/dev/null | grep 'com.apple.TimeMachine' | while read -r s; do
    d="${s#com.apple.TimeMachine.}"; d="${d%.local}"
    add_candidate "TM snapshot" "$d" "snapshot:$d" "0" "-" "CAUTION" "size unknown before deletion; macOS purges them on its own when needed" "cmd:tmutil deletelocalsnapshots $d"
  done
fi

# Trash
kb=$(du_kb "$HOME/.Trash")
(( kb > 10240 )) && add_candidate "Trash" "~/.Trash" "$HOME/.Trash" "$kb" "$(newest_age_days "$HOME/.Trash")" "CAUTION" "irreversible once emptied" "rm-contents:$HOME/.Trash"

# iOS backups, Mail attachments
MB="$HOME/Library/Application Support/MobileSync/Backup"
[[ -d "$MB" ]] && { kb=$(du_kb "$MB"); (( kb > 10240 )) && add_candidate "iOS backups" "MobileSync/Backup" "$MB" "$kb" "$(newest_age_days "$MB")" "MANUAL" "manage in Finder > device > Manage Backups" "none"; }
MD="$HOME/Library/Containers/com.apple.mail/Data/Library/Mail Downloads"
[[ -d "$MD" ]] && { kb=$(du_kb "$MD"); (( kb > 10240 )) && add_candidate "Mail" "Mail Downloads (opened attachments)" "$MD" "$kb" "$(newest_age_days "$MD")" "SAFE" "temporary copies; the originals stay in the messages" "rm-contents:$MD"; }

# node_modules / .venv / target of inactive projects
h2 "Dependencies of inactive projects (node_modules, .venv, target)"
find "$HOME" -maxdepth 6 \( -name node_modules -o -name .venv -o -name venv -o -name target \) -type d -prune \
  -not -path "$HOME/Library/*" -not -path "$HOME/.*" 2>/dev/null | while read -r d; do
  proj="${d:h}"
  [[ "${d:t}" == "target" && ! -f "$proj/Cargo.toml" ]] && continue
  skip=0; for ap in "${ACTIVE_PROJECTS[@]}"; do [[ "$proj" == "$ap" || "$proj" == "$ap"/* ]] && skip=1; done
  (( skip )) && continue
  kb=$(du_kb "$d"); (( kb < 51200 )) && continue
  age=$(newest_age_days "$proj")
  (( age < ACTIVE_DAYS )) && continue
  add_candidate "Inactive project" "${proj/#$HOME/~}/${d:t}" "$d" "$kb" "$age" "CAUTION" "project inactive for ${age} d; reinstallable (npm i / pip / cargo)" "rm-path:$d"
done

# Downloads: large old files (list only)
h2 "Large downloads older than 90 d (list only)"
find "$HOME/Downloads" -maxdepth 1 -type f -size +100M -mtime +90 -print0 2>/dev/null \
  | xargs -0 du -sk 2>/dev/null | sort -rn | head -"$TOP" | while read -r kb f; do
    info "$(printf '%9s' "$(human $kb)")  ${f/#$HOME/~}"
  done
kb=$(find "$HOME/Downloads" -maxdepth 1 -type f -size +100M -mtime +90 -print0 2>/dev/null | xargs -0 du -sk 2>/dev/null | awk '{s+=$1} END{print s+0}')
(( kb > 0 )) && add_candidate "Downloads" "~/Downloads: files > 100 MB and > 90 d" "$HOME/Downloads" "$kb" "90+" "MANUAL" "sort by hand" "none"

# Application data (informational: never touched, but often where the weight is)
h2 "Top $TOP of ~/Library/Application Support and ~/Library/Containers (informational, MANUAL)"
{ du -xk -d 1 "$HOME/Library/Application Support" 2>/dev/null; du -xk -d 1 "$HOME/Library/Containers" 2>/dev/null; } \
  | sort -rn | awk -F'\t' -v a="$HOME/Library/Application Support" -v c="$HOME/Library/Containers" '$2!=a && $2!=c' | head -"$TOP" | while IFS=$'\t' read -r kb d; do
    info "$(printf '%9s' "$(human $kb)")  ${d/#$HOME/~}"
  done

AC="$HOME/Library/Application Support/com.apple.container"
[[ -d "$AC" ]] && { kb=$(du_kb "$AC"); (( kb > 102400 )) && add_candidate "Apple Container" "images/VMs of Apple's 'container' tool" "$AC" "$kb" "$(newest_age_days "$AC")" "MANUAL" "container image prune / container system stop, then delete by hand" "none"; }
MW="$HOME/Library/Application Support/MacWhisper"
[[ -d "$MW" ]] && { kb=$(du_kb "$MW"); (( kb > 102400 )) && add_candidate "MacWhisper model" "downloaded Whisper models" "$MW" "$kb" "$(newest_age_days "$MW")" "MANUAL" "manage in MacWhisper > Models" "none"; }

# Top folders of the home (overview)
if (( ! FAST )); then
  h2 "Top $TOP folders of ~ (depth 2, overview)"
  du -xk -d 2 "$HOME" 2>/dev/null | sort -rn | awk -v home="$HOME" 'NR>1 && NR<=1000 {print}' | head -"$TOP" | while read -r kb d; do
    info "$(printf '%9s' "$(human $kb)")  ${d/#$HOME/~}"
  done
fi

# ----------------------------------------------------------------------------
# 6. Cleanup plan
# ----------------------------------------------------------------------------
h1 "6. Cleanup plan"

typeset -a ORDER
# sort by decreasing size
for i in {1..${#CAND_PATH}}; do print -- "${CAND_KB[$i]} $i"; done | sort -rn | awk '{print $2}' | while read -r i; do ORDER+=("$i"); done

describe_action() {
  local kind="${1%%:*}" arg="${1#*:}"
  case "$kind" in
    rm-contents)  print -- "empty ${arg/#$HOME/~}/" ;;
    rm-path)      print -- "delete ${arg/#$HOME/~}" ;;
    rm-old-files) print -- "delete files > ${arg##*:} d in ${${arg%:*}/#$HOME/~}" ;;
    cmd)          print -- "$arg" ;;
    sudo)         print -- "sudo $arg" ;;
    *)            print -- "$1" ;;
  esac
}

SAFE_KB=0 CAUT_KB=0 MAN_KB=0 SAFE_N=0 CAUT_N=0 MAN_N=0
print_group() {  # print_group VERDICT TITLE
  local want="$1" title="$2" i shown=0
  for i in "${ORDER[@]}"; do
    [[ "${CAND_VERDICT[$i]}" == "$want" ]] || continue
    if (( ! shown )); then h2 "$title"; shown=1; fi
    printf "  %-9s  %-16s  %-48s  %s\n" "$(human ${CAND_KB[$i]})" "${CAND_CAT[$i]}" "${CAND_LABEL[$i]:0:48}" "${C_DIM}${CAND_REASON[$i]}${C_RESET}"
    [[ "${CAND_ACTION[$i]}" != "none" ]] && printf "  %-9s  %-16s  ${C_DIM}→ %s${C_RESET}\n" "" "" "$(describe_action "${CAND_ACTION[$i]}")"
  done
  (( shown )) || { h2 "$title"; info "(nothing)"; }
}
for i in {1..${#CAND_PATH}}; do
  case "${CAND_VERDICT[$i]}" in
    SAFE)    (( SAFE_KB += CAND_KB[$i] )); (( SAFE_N++ )) ;;
    CAUTION) (( CAUT_KB += CAND_KB[$i] )); (( CAUT_N++ )) ;;
    MANUAL)  (( MAN_KB  += CAND_KB[$i] )); (( MAN_N++ )) ;;
  esac
done

print_group "SAFE"    "${C_GREEN}A. SAFE — run in one batch after confirmation (${SAFE_N} items, ≈ $(human $SAFE_KB))${C_RESET}"
print_group "CAUTION" "${C_YELLOW}B. CAUTION — asked one by one (${CAUT_N} items, ≈ $(human $CAUT_KB))${C_RESET}"
print_group "MANUAL"  "${C_DIM}C. MANUAL — never touched by the script (${MAN_N} items, ≈ $(human $MAN_KB))${C_RESET}"

print
say "${C_BOLD}Summary${C_RESET}: safely reclaimable ≈ ${C_GREEN}$(human $SAFE_KB)${C_RESET} · with caution ≈ ${C_YELLOW}$(human $CAUT_KB)${C_RESET} · to sort by hand ≈ $(human $MAN_KB)"
say "Active projects protected: ${#ACTIVE_PROJECTS} · Spotlight: $( ((SPOT_SUSPECT)) && print -- "${C_RED}SUSPECT${C_RESET}" || print -- "${C_GREEN}healthy${C_RESET}" )"

if (( DRY_RUN )); then
  print
  dim "--dry-run mode: nothing was deleted. Rerun without --dry-run to execute the plan."
  exit 0
fi

# ----------------------------------------------------------------------------
# 7. Execution
# ----------------------------------------------------------------------------
h1 "7. Execution"

run_action() {  # run_action ACTION  -> executes, 0 on success
  local a="$1" kind="${1%%:*}" arg="${1#*:}" p days
  case "$kind" in
    rm-contents) p="$arg"; [[ -d "$p" && "$p" == "$HOME"/* ]] || { bad "path refused: $p"; return 1; }
                 find "$p" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null ;;
    rm-path)     p="$arg"; [[ -e "$p" && "$p" == "$HOME"/* && "$p" != "$HOME" ]] || { bad "path refused: $p"; return 1; }
                 rm -rf "$p" ;;
    rm-old-files) p="${arg%:*}"; days="${arg##*:}"
                 find "$p" -type f -mtime +"$days" -delete 2>/dev/null
                 find "$p" -mindepth 1 -type d -empty -delete 2>/dev/null ;;
    cmd)         eval "$arg" ;;
    sudo)        sudo $=arg ;;
    none)        return 0 ;;
    *)           bad "unknown action: $a"; return 1 ;;
  esac
}

ask() {  # ask "question" -> 0 if yes
  local r
  print -n -- "$1 "
  read -r r
  [[ "$r" == "yes" || "$r" == "y" ]]
}

FREED_BEFORE=$(df -k "$DATA_VOL" | tail -1 | awk '{print $4}')
DONE_N=0

if (( SAFE_N > 0 )); then
  if (( ASSUME_YES )) || ask "Run the ${SAFE_N} SAFE actions (≈ $(human $SAFE_KB))? Type ${C_BOLD}yes${C_RESET}:"; then
    for i in "${ORDER[@]}"; do
      [[ "${CAND_VERDICT[$i]}" == "SAFE" && "${CAND_ACTION[$i]}" != "none" ]] || continue
      print -n -- "  ${CAND_LABEL[$i]:0:60} … "
      if run_action "${CAND_ACTION[$i]}" >> "$LOG_FILE" 2>&1; then print -- "${C_GREEN}ok${C_RESET}"; (( DONE_N++ )); else print -- "${C_RED}failed (see log)${C_RESET}"; fi
    done
  else
    info "SAFE actions skipped."
  fi
fi

if (( CAUT_N > 0 )) && [[ -t 0 ]]; then
  print
  say "CAUTION actions — answer ${C_BOLD}y${C_RESET}es / ${C_BOLD}N${C_RESET}o / ${C_BOLD}q${C_RESET}uit for each one:"
  for i in "${ORDER[@]}"; do
    [[ "${CAND_VERDICT[$i]}" == "CAUTION" && "${CAND_ACTION[$i]}" != "none" ]] || continue
    print -n -- "  [$(human ${CAND_KB[$i]})] ${CAND_CAT[$i]} · ${CAND_LABEL[$i]:0:50} — ${C_DIM}${CAND_REASON[$i]}${C_RESET}  [y/N/q] "
    read -r r
    case "$r" in
      q|Q) break ;;
      y|Y|yes)
        if run_action "${CAND_ACTION[$i]}" >> "$LOG_FILE" 2>&1; then ok "done"; (( DONE_N++ )); else bad "failed (see log)"; fi ;;
      *) info "skipped" ;;
    esac
  done
elif (( CAUT_N > 0 )); then
  info "CAUTION actions not offered (no interactive terminal)."
fi

sleep 2
FREED_AFTER=$(df -k "$DATA_VOL" | tail -1 | awk '{print $4}')
FREED=$(( FREED_AFTER - FREED_BEFORE )); (( FREED < 0 )) && FREED=0
print
say "${C_BOLD}Done${C_RESET}: ${DONE_N} action(s) executed · space freed ≈ ${C_GREEN}$(human $FREED)${C_RESET} · free now: $(human $FREED_AFTER)"
dim "(APFS sometimes frees space with a delay; deleted snapshots are purged in the background.)"
dim "Full log: $LOG_FILE"
