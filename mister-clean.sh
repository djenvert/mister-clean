#!/bin/zsh
# =============================================================================
# mister-clean.sh — Audit disque macOS : Spotlight, caches, vieux modèles IA,
#                   gros volumes, protection des projets en cours, plan de
#                   nettoyage (affiché en --dry-run, exécuté après confirmation).
#
# Usage :
#   ./mister-clean.sh --dry-run            # audit + plan, aucune suppression
#   ./mister-clean.sh                      # audit + plan + confirmation + exécution
#
# Options :
#   --dry-run          N'exécute rien, affiche seulement le plan.
#   --yes              Exécute les actions SÛRES sans demander (les actions
#                      PRUDENCE restent demandées une par une, jamais en --yes).
#   --days N           Un cache non modifié depuis N jours est "inutilisé" (30).
#   --model-days N     Un modèle non touché depuis N jours est "ancien" (90).
#   --active-days N    Un projet modifié depuis N jours est "en cours" (30).
#   --top N            Nombre de lignes dans les classements (20).
#   --fast             Saute les étapes lentes (journal système, du profonds).
#   --skip-spotlight   Saute l'audit Spotlight.
#   -h, --help         Cette aide.
#
# Verdicts :
#   SÛR       Cache régénérable, aucun fichier ouvert, aucun projet en cours
#             concerné → supprimé en bloc après la confirmation globale.
#   PRUDENCE  Récupérable mais coûteux (modèles, snapshots, caches récents…)
#             → demandé item par item.
#   MANUEL    Jamais touché par le script (archives Xcode, sauvegardes iOS,
#             Téléchargements…) → simplement listé.
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

usage() { sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }

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
    *) print -u2 "Option inconnue : $1 (voir --help)"; exit 2 ;;
  esac
  shift
done

if [[ "$(uname -s)" != "Darwin" ]]; then
  print -u2 "Ce script est conçu pour macOS uniquement."; exit 1
fi

# ----------------------------------------------------------------------------
# Sortie, journal, couleurs
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

# Tout ce qui est affiché est aussi journalisé (sans les codes couleur).
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
# Utilitaires
# ----------------------------------------------------------------------------
human() {  # KiB -> lisible
  local kb=${1:-0}
  if (( kb >= 1073741824 )); then printf "%.1f TiB" $(( kb / 1073741824.0 ))
  elif (( kb >= 1048576 ));  then printf "%.1f GiB" $(( kb / 1048576.0 ))
  elif (( kb >= 1024 ));     then printf "%.0f MiB" $(( kb / 1024.0 ))
  else printf "%d KiB" $kb; fi
}

du_kb() {  # taille d'un chemin en KiB (0 si absent)
  [[ -e "$1" ]] || { print 0; return; }
  local r
  r=$(du -sk "$1" 2>/dev/null | cut -f1)
  print -- "${r:-0}"
}

dir_kb_sum() {  # somme des tailles d'une liste de chemins (stdin)
  local total=0 p
  while IFS= read -r p; do
    [[ -n "$p" ]] && (( total += $(du_kb "$p") ))
  done
  print -- $total
}

# Nombre de jours depuis la modification la plus récente (profondeur limitée).
newest_age_days() {
  local p="$1" now newest
  now=$(date +%s)
  newest=$( { stat -f %m "$p"; find "$p" -maxdepth 3 -print0 2>/dev/null | xargs -0 stat -f %m 2>/dev/null; } | sort -rn | head -1 )
  [[ -z "$newest" ]] && { print 9999; return; }
  print -- $(( (now - newest) / 86400 ))
}

is_recent() {  # 0 si un fichier a été modifié depuis moins de N jours
  local p="$1" days="$2"
  [[ -n "$(find "$p" -type f -mtime -"$days" -print -quit 2>/dev/null)" ]]
}

run_with_timeout() {  # run_with_timeout SECONDES cmd...
  local s="$1"; shift
  perl -e 'alarm shift; exec @ARGV' "$s" "$@"
}

have() { command -v "$1" >/dev/null 2>&1; }
is_running() { pgrep -x "$1" >/dev/null 2>&1; }

# ----------------------------------------------------------------------------
# Registre des candidats au nettoyage
# ----------------------------------------------------------------------------
typeset -a CAND_CAT CAND_LABEL CAND_PATH CAND_KB CAND_AGE CAND_VERDICT CAND_REASON CAND_ACTION
typeset -a OPEN_FILES ACTIVE_PROJECTS

# add_candidate CAT LABEL PATH KB AGE VERDICT RAISON ACTION
add_candidate() {
  CAND_CAT+=("$1"); CAND_LABEL+=("$2"); CAND_PATH+=("$3"); CAND_KB+=("$4")
  CAND_AGE+=("$5"); CAND_VERDICT+=("$6"); CAND_REASON+=("$7"); CAND_ACTION+=("$8")
}

# Un chemin est-il "touché" par un projet en cours ou un fichier ouvert ?
# Affiche la raison, vide si rien.
conflict_reason() {
  local p="$1" proj f
  for proj in "${ACTIVE_PROJECTS[@]}"; do
    [[ "$p" == "$proj" || "$p" == "$proj"/* ]] && { print -- "dans le projet en cours $proj"; return; }
  done
  if [[ -s "$TMP/open_files" ]] && grep -q -F -- "$p/" "$TMP/open_files"; then
    f=$(grep -F -- "$p/" "$TMP/open_files" | head -1)
    print -- "fichier ouvert par un processus : ${f#$p/}"
    return
  fi
  print -- ""
}

# Décide SÛR / PRUDENCE selon l'âge et les conflits.
# verdict_for PATH DAYS_THRESHOLD "raison si PRUDENCE forcée"
verdict_for() {
  local p="$1" days="$2" forced="${3:-}" c
  c=$(conflict_reason "$p")
  if [[ -n "$c" ]]; then print -- "PRUDENCE|$c"; return; fi
  if [[ -n "$forced" ]]; then print -- "PRUDENCE|$forced"; return; fi
  if is_recent "$p" "$days"; then
    print -- "PRUDENCE|modifié il y a moins de $days j (encore utilisé, sera régénéré)"
  else
    print -- "SÛR|non modifié depuis ≥ $days j, régénérable"
  fi
}

# ----------------------------------------------------------------------------
# En-tête
# ----------------------------------------------------------------------------
print -r -- "${C_BOLD}${C_CYAN}mister-clean v$VERSION${C_RESET} — $(date '+%Y-%m-%d %H:%M')  $( ((DRY_RUN)) && print -- '[DRY-RUN]' )"
dim "macOS $(sw_vers -productVersion) · $(uname -m) · journal : $LOG_FILE"
dim "Seuils : cache inutilisé ≥ ${CACHE_DAYS} j · modèle ancien ≥ ${MODEL_DAYS} j · projet en cours ≤ ${ACTIVE_DAYS} j"

h1 "0. État du disque"
DATA_VOL="/System/Volumes/Data"
[[ -d "$DATA_VOL" ]] || DATA_VOL="/"
DF_LINE=$(df -k "$DATA_VOL" | tail -1)
DISK_TOTAL_KB=$(print -- "$DF_LINE" | awk '{print $2}')
DISK_USED_KB=$(print -- "$DF_LINE" | awk '{print $3}')
DISK_FREE_KB=$(print -- "$DF_LINE" | awk '{print $4}')
info "Volume données : $(human $DISK_USED_KB) utilisés / $(human $DISK_TOTAL_KB) · libre : $(human $DISK_FREE_KB)"
PURGEABLE=$(diskutil info "$DATA_VOL" 2>/dev/null | awk -F: '/Purgeable/ {gsub(/^ +/,"",$2); print $2}' | head -1)
[[ -n "$PURGEABLE" ]] && info "Espace purgeable (macOS peut le libérer seul) : $PURGEABLE"
SNAP_COUNT=$(tmutil listlocalsnapshots / 2>/dev/null | grep -c 'com.apple.TimeMachine')
info "Snapshots Time Machine locaux : $SNAP_COUNT"

# Accès complet au disque (TCC) : sans lui, ~/Documents, ~/Desktop et les résultats
# de mdfind sont masqués à ce terminal → les contre-vérifications Spotlight seraient faussées.
TCC_OK=1
if ! ls "$HOME/Desktop" >/dev/null 2>&1 && [[ -d "$HOME/Desktop" ]]; then TCC_OK=0; fi
if (( TCC_OK )); then ok "Accès complet au disque : OK pour ce terminal."
else
  warn "Ce terminal n'a PAS l'Accès complet au disque (Réglages > Confidentialité et sécurité)."
  warn "Les tests Spotlight par échantillon/sonde seront marqués NON CONCLUANTS, et certains caches ne seront pas vus."
fi

# ----------------------------------------------------------------------------
# 1. Projets en cours & fichiers ouverts  (le filet de sécurité)
# ----------------------------------------------------------------------------
h1 "1. Projets en cours et fichiers ouverts (filet de sécurité)"

info "Dépôts git modifiés depuis ${ACTIVE_DAYS} j…"
while IFS= read -r gitdir; do
  proj="${gitdir:h}"
  if [[ -n "$(find "$proj" -maxdepth 4 -type f -mtime -"$ACTIVE_DAYS" \
        -not -path '*/node_modules/*' -not -path '*/.git/*' -print -quit 2>/dev/null)" ]]; then
    ACTIVE_PROJECTS+=("$proj")
  fi
done < <(find "$HOME" -maxdepth 5 -name .git -type d \
          -not -path "$HOME/Library/*" -not -path "$HOME/.Trash/*" \
          -not -path '*/node_modules/*' -not -path "$HOME/.*/*" 2>/dev/null)

info "Fichiers ouverts par vos processus (lsof)…"
lsof -n -u "$USER" -F n 2>/dev/null | sed -n 's/^n//p' | grep "^$HOME/" | sort -u > "$TMP/open_files" || true
# Répertoires de travail des shells/éditeurs = projets en cours aussi
lsof -n -u "$USER" -a -d cwd -F n 2>/dev/null | sed -n 's/^n//p' | grep "^$HOME/" | grep -v "^$HOME/Library" | sort -u > "$TMP/cwds" || true
while IFS= read -r d; do
  [[ "$d" == "$HOME" ]] && continue
  # on remonte au dépôt git s'il existe
  r="$d"; while [[ "$r" != "$HOME" && "$r" != "/" && ! -d "$r/.git" ]]; do r="${r:h}"; done
  [[ -d "$r/.git" ]] && d="$r"
  (( ${ACTIVE_PROJECTS[(Ie)$d]} )) || ACTIVE_PROJECTS+=("$d")
done < "$TMP/cwds"

if (( ${#ACTIVE_PROJECTS} )); then
  ok "${#ACTIVE_PROJECTS} projet(s) considéré(s) en cours — rien n'y sera touché :"
  for p in "${ACTIVE_PROJECTS[@]}"; do info "  ${p/#$HOME/~}"; done
else
  ok "Aucun projet actif détecté."
fi
info "$(wc -l < "$TMP/open_files" | tr -d ' ') fichiers ouverts sous ~ (tout cache contenant l'un d'eux passera en PRUDENCE)."

typeset -a RUNNING_APPS
for app in Xcode ollama "Docker" "Code" "Cursor" "Google Chrome" Safari Arc Firefox Slack Spotify "LM Studio"; do
  is_running "$app" && RUNNING_APPS+=("$app")
done
(( ${#RUNNING_APPS} )) && info "Apps en cours d'exécution : ${(j:, :)RUNNING_APPS}"

# ----------------------------------------------------------------------------
# 2. Spotlight — contre-vérification
# ----------------------------------------------------------------------------
SPOT_SUSPECT=0
typeset -a SPOT_FINDINGS
if (( ! SKIP_SPOTLIGHT )); then
  h1 "2. Spotlight — contre-vérification de l'index"

  h2 "2a. État de l'indexation par volume (mdutil)"
  typeset -a VOLS; VOLS=("/")
  while IFS= read -r v; do VOLS+=("$v"); done < <(mount | grep -E '^/dev/.* on /Volumes/' | grep -v nobrowse | sed -E 's#^/dev/[^ ]+ on (/Volumes/.*) \(.*$#\1#')
  for v in "${VOLS[@]}"; do
    st=$(mdutil -s "$v" 2>&1 | tail -1 | sed 's/^[[:space:]]*//')
    case "$st" in
      *"Indexing enabled"*) ok "$v : $st" ;;
      *"disabled"*)         warn "$v : $st (volume exclu de Spotlight — pas d'index à nettoyer)" ;;
      *"could not resolve"*) warn "$v : non accessible à ce terminal ($st)" ;;
      *) bad "$v : $st"; SPOT_FINDINGS+=("mdutil signale un état anormal sur $v : $st"); (( SPOT_SUSPECT++ )) ;;
    esac
  done

  h2 "2b. Taille des index vs taille des données"
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
    info "Index système : $(human $SPOT_IDX_KB) ($(printf '%.2f' $ratio) % des données). Normal : 0,5 – 3 %."
    if (( ratio > 8 )); then
      bad "Ratio anormalement élevé → index gonflé/obsolète probable."
      SPOT_FINDINGS+=("index système = $(printf '%.1f' $ratio) % des données (attendu < 3 %)"); (( SPOT_SUSPECT++ ))
    fi
  else
    warn "Index système non mesurable sans sudo (Accès complet au disque requis). Relancer avec 'sudo -v' avant si besoin."
  fi
  info "Index utilisateur (CoreSpotlight) : $(human $USER_IDX_KB)"

  h2 "2c. Contre-vérification n°1 — échantillon de fichiers réels vs index"
  SAMPLE_DIR=""
  for cand in "$HOME/Documents" "$HOME/Desktop" "$HOME/Pictures" "$HOME/Movies" "$HOME/Music" "$HOME"; do
    [[ -d "$cand" ]] && ls "$cand" >/dev/null 2>&1 && [[ -n "$(find "$cand" -maxdepth 3 -type f -not -path '*/.*' -print -quit 2>/dev/null)" ]] && { SAMPLE_DIR="$cand"; break; }
  done
  [[ -z "$SAMPLE_DIR" ]] && SAMPLE_DIR="$HOME"
  info "Dossier échantillonné : ${SAMPLE_DIR/#$HOME/~}"
  # On ignore les fichiers cachés et l'intérieur des paquets (.app, .pages…) que Spotlight indexe comme un seul objet.
  find "$SAMPLE_DIR" -type f -not -path '*/.*' \
    -not -path '*.app/*' -not -path '*.pages/*' -not -path '*.numbers/*' -not -path '*.key/*' \
    -not -path '*.photoslibrary/*' -not -path '*.bundle/*' -not -path '*.framework/*' \
    -not -path '*/node_modules/*' -mtime +1 2>/dev/null | head -5000 | sort -R | head -40 > "$TMP/sample"
  n=$(wc -l < "$TMP/sample" | tr -d ' '); miss=0
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    b="${f:t}"
    if ! mdfind -onlyin "${f:h}" -name "$b" 2>/dev/null | grep -qxF -- "$f"; then
      (( miss++ )); (( miss <= 5 )) && info "  absent de l'index : ${f/#$HOME/~}"
    fi
  done < "$TMP/sample"
  if (( ! TCC_OK )); then
    warn "NON CONCLUANT : $miss / $n absents, mais mdfind est bridé sans Accès complet au disque. Relancez depuis Terminal.app avec l'accès accordé."
  elif (( n == 0 )); then
    warn "Aucun fichier échantillonnable dans $SAMPLE_DIR."
  else
    pct=$(( miss * 100 / n ))
    if (( pct > 20 )); then
      bad "$miss / $n fichiers (${pct} %) connus du disque mais inconnus de Spotlight → index incomplet/corrompu."
      SPOT_FINDINGS+=("$miss/$n fichiers échantillonnés absents de l'index"); (( SPOT_SUSPECT++ ))
    elif (( pct > 5 )); then
      warn "$miss / $n fichiers absents de l'index (${pct} %) — tolérable, mais à surveiller."
    else
      ok "$miss / $n fichiers absents de l'index (${pct} %) — l'index reflète le disque."
    fi
  fi

  h2 "2d. Contre-vérification n°2 — sonde en direct (le démon indexe-t-il encore ?)"
  PROBE="$HOME/mister-clean-probe-$RUN_ID.txt"
  print -- "mister-clean probe $RUN_ID" > "$PROBE" 2>/dev/null
  found=0
  for i in {1..15}; do
    sleep 1
    if mdfind -name "mister-clean-probe-$RUN_ID" 2>/dev/null | grep -q .; then found=$i; break; fi
  done
  rm -f "$PROBE"
  if (( found )); then ok "Nouveau fichier indexé en ${found} s — mds fonctionne."
  elif (( ! TCC_OK )); then warn "NON CONCLUANT : sonde invisible, mais mdfind est bridé pour ce terminal (voir plus haut)."
  else bad "Nouveau fichier toujours non indexé après 15 s → indexation bloquée ou en panne."
       SPOT_FINDINGS+=("sonde non indexée après 15 s"); (( SPOT_SUSPECT++ )); fi

  h2 "2e. Contre-vérification n°3 — journal système et processus mds"
  if (( FAST )); then
    info "(--fast) journal système ignoré."
  else
    run_with_timeout 120 log show --last 2h --style compact \
        --predicate 'process == "mds" OR process == "mds_stores" OR process BEGINSWITH "mdworker"' 2>/dev/null \
      | grep -iE 'corrupt|damaged|invalid index|rebuilding index|reset index|index.*unusable' > "$TMP/mdslog" || true
    errs=$(wc -l < "$TMP/mdslog" | tr -d ' ')
    if (( errs > 0 )); then
      bad "$errs message(s) évoquant une corruption de l'index dans les 2 dernières heures :"
      head -3 "$TMP/mdslog" | cut -c1-200 | sed 's/^/      /'
      SPOT_FINDINGS+=("$errs messages de corruption dans le journal mds"); (( SPOT_SUSPECT++ ))
    else ok "Aucun message de corruption dans le journal mds (2 h)."; fi
  fi
  mdcpu=$(ps -Ao %cpu,comm | awk '$2 ~ /mds_stores|mdworker|mds$/ {s+=$1} END {printf "%.0f", s+0}')
  if (( mdcpu > 150 )); then warn "mds/mdworker consomment ${mdcpu} % CPU : réindexation en cours ou boucle."
  else info "CPU cumulé mds/mdworker : ${mdcpu} %"; fi

  h2 "2f. Verdict Spotlight"
  if (( SPOT_SUSPECT == 0 && ! TCC_OK )); then
    warn "Aucun signe de corruption sur les tests disponibles, mais 2 tests sur 3 sont NON CONCLUANTS sans Accès complet au disque."
  elif (( SPOT_SUSPECT == 0 )); then
    ok "Index SAIN : les ${C_BOLD}3 contre-vérifications${C_RESET} concordent (échantillon, sonde, journal). Pas de reconstruction nécessaire."
  else
    bad "Index SUSPECT ($SPOT_SUSPECT indice(s)) :"
    for f in "${SPOT_FINDINGS[@]}"; do info "  – $f"; done
    add_candidate "Spotlight" "Reconstruire l'index Spotlight (mdutil -E /)" "$SPOT_IDX" "$SPOT_IDX_KB" "-" \
      "PRUDENCE" "index suspect ; la reconstruction efface l'index gonflé puis réindexe (CPU pendant 1–3 h)" \
      "sudo:mdutil -E /"
  fi
fi

# ----------------------------------------------------------------------------
# 3. Caches
# ----------------------------------------------------------------------------
h1 "3. Scan des caches"

scan_cache_dir() {  # scan_cache_dir CATEGORIE RACINE  (chaque sous-dossier devient un candidat)
  local cat="$1" root="$2" d kb age v reason forced
  [[ -d "$root" ]] || return 0
  for d in "$root"/*(N); do
    [[ "${d:t}" == "Homebrew" || "${d:t}" == "pip" ]] && continue   # gérés par leur outil (brew cleanup, pip cache purge)
    kb=$(du_kb "$d"); (( kb < 10240 )) && continue   # < 10 MiB : pas la peine
    age=$(newest_age_days "$d")
    forced=""
    case "${d:t}" in
      com.apple.*) forced="cache Apple ; régénéré mais parfois volumineux à reconstruire (ex. Photos, iCloud)" ;;
      CloudKit*|com.apple.bird*) forced="lié à iCloud" ;;
    esac
    IFS='|' read -r v reason <<< "$(verdict_for "$d" "$CACHE_DAYS" "$forced")"
    add_candidate "$cat" "${d:t}" "$d" "$kb" "$age" "$v" "$reason" "rm-contents:$d"
  done
}

info "~/Library/Caches…";   scan_cache_dir "Cache app" "$HOME/Library/Caches"
info "~/.cache…";           scan_cache_dir "Cache CLI" "$HOME/.cache"

# Journaux
for logroot in "$HOME/Library/Logs" "/Library/Logs/DiagnosticReports" "$HOME/Library/Logs/DiagnosticReports"; do
  [[ -d "$logroot" ]] || continue
  kb=$(find "$logroot" -type f -mtime +"$CACHE_DAYS" -print0 2>/dev/null | xargs -0 du -sk 2>/dev/null | awk '{s+=$1} END {print s+0}')
  (( kb < 5120 )) && continue
  add_candidate "Journaux" "${logroot/#$HOME/~} (fichiers > ${CACHE_DAYS} j)" "$logroot" "$kb" "$CACHE_DAYS+" \
    "SÛR" "journaux anciens, sans valeur sauf diagnostic en cours" "rm-old-files:$logroot:$CACHE_DAYS"
done

# Outils développeur
h2 "Outils développeur"
XC="$HOME/Library/Developer/Xcode"
if [[ -d "$XC/DerivedData" ]]; then
  kb=$(du_kb "$XC/DerivedData"); forced=""; is_running Xcode && forced="Xcode est ouvert : fermez-le avant"
  IFS='|' read -r v reason <<< "$(verdict_for "$XC/DerivedData" "$CACHE_DAYS" "$forced")"
  (( kb > 0 )) && add_candidate "Xcode" "DerivedData (builds intermédiaires)" "$XC/DerivedData" "$kb" "$(newest_age_days "$XC/DerivedData")" "$v" "$reason" "rm-contents:$XC/DerivedData"
fi
for ds in "$XC"/*DeviceSupport(N); do
  kb=$(du_kb "$ds"); (( kb > 0 )) && add_candidate "Xcode" "${ds:t} (symboles d'anciens OS)" "$ds" "$kb" "$(newest_age_days "$ds")" \
    "SÛR" "retéléchargé à la prochaine connexion d'un appareil" "rm-contents:$ds"
done
[[ -d "$XC/Archives" ]] && { kb=$(du_kb "$XC/Archives"); (( kb > 0 )) && add_candidate "Xcode" "Archives (.xcarchive + dSYM)" "$XC/Archives" "$kb" "$(newest_age_days "$XC/Archives")" \
    "MANUEL" "contient les symboles des versions publiées : à trier à la main" "none"; }
CS="$HOME/Library/Developer/CoreSimulator"
[[ -d "$CS/Caches" ]] && { kb=$(du_kb "$CS/Caches"); (( kb > 0 )) && add_candidate "Simulateur" "CoreSimulator/Caches" "$CS/Caches" "$kb" "$(newest_age_days "$CS/Caches")" \
    "$(verdict_for "$CS/Caches" "$CACHE_DAYS" | cut -d'|' -f1)" "$(verdict_for "$CS/Caches" "$CACHE_DAYS" | cut -d'|' -f2)" "rm-contents:$CS/Caches"; }
if [[ -d "$CS/Devices" ]] && have xcrun; then
  kb=$(du_kb "$CS/Devices")
  (( kb > 0 )) && add_candidate "Simulateur" "Simulateurs indisponibles (runtime désinstallé)" "$CS/Devices" "$kb" "-" \
    "SÛR" "xcrun simctl delete unavailable ne retire que les simulateurs orphelins" "cmd:xcrun simctl delete unavailable"
fi

# Gestionnaires de paquets
h2 "Gestionnaires de paquets"
if have brew; then
  bc=$(brew --cache 2>/dev/null); kb=$(du_kb "$bc")
  (( kb > 0 )) && add_candidate "Homebrew" "cache des téléchargements + vieilles versions" "$bc" "$kb" "$(newest_age_days "$bc")" \
    "SÛR" "brew cleanup --prune=all -s retire bouteilles et téléchargements obsolètes" "cmd:brew cleanup --prune=all -s"
fi
[[ -d "$HOME/.npm/_cacache" ]] && { kb=$(du_kb "$HOME/.npm/_cacache"); (( kb > 0 )) && add_candidate "npm" "cache npm (_cacache)" "$HOME/.npm/_cacache" "$kb" "$(newest_age_days "$HOME/.npm/_cacache")" \
    "SÛR" "retéléchargé à la demande" "cmd:npm cache clean --force"; }
if have pnpm; then
  ps_=$(pnpm store path 2>/dev/null); [[ -d "$ps_" ]] && { kb=$(du_kb "$ps_"); (( kb > 0 )) && add_candidate "pnpm" "store pnpm (paquets orphelins)" "$ps_" "$kb" "$(newest_age_days "$ps_")" \
    "SÛR" "pnpm store prune ne retire que les paquets non référencés" "cmd:pnpm store prune"; }
fi
if have yarn; then
  yc=$(yarn cache dir 2>/dev/null); [[ -d "$yc" ]] && { kb=$(du_kb "$yc"); (( kb > 10240 )) && add_candidate "yarn" "cache yarn" "$yc" "$kb" "$(newest_age_days "$yc")" \
    "SÛR" "retéléchargé à la demande" "cmd:yarn cache clean"; }
fi
have pip3 && { pc=$(pip3 cache dir 2>/dev/null); [[ -d "$pc" && "$pc" != "$HOME/Library/Caches/pip" ]] && { kb=$(du_kb "$pc"); (( kb > 10240 )) && add_candidate "pip" "cache pip" "$pc" "$kb" "$(newest_age_days "$pc")" "SÛR" "retéléchargé à la demande" "cmd:pip3 cache purge"; }; }
have uv && { uc=$(uv cache dir 2>/dev/null); [[ -d "$uc" ]] && { kb=$(du_kb "$uc"); (( kb > 10240 )) && add_candidate "uv" "cache uv" "$uc" "$kb" "$(newest_age_days "$uc")" "SÛR" "uv cache prune ne retire que l'inutilisé" "cmd:uv cache prune"; }; }
[[ -d "$HOME/.cargo/registry" ]] && { kb=$(du_kb "$HOME/.cargo/registry"); (( kb > 10240 )) && add_candidate "cargo" "registry Rust (sources + crates)" "$HOME/.cargo/registry" "$kb" "$(newest_age_days "$HOME/.cargo/registry")" \
    "PRUDENCE" "retéléchargé au prochain build, mais lent hors-ligne" "rm-contents:$HOME/.cargo/registry/cache"; }
[[ -d "$HOME/go/pkg/mod" ]] && { kb=$(du_kb "$HOME/go/pkg/mod"); (( kb > 10240 )) && add_candidate "go" "cache modules Go" "$HOME/go/pkg/mod" "$kb" "$(newest_age_days "$HOME/go/pkg/mod")" \
    "PRUDENCE" "retéléchargé au prochain build" "cmd:go clean -modcache"; }
[[ -d "$HOME/.gradle/caches" ]] && { kb=$(du_kb "$HOME/.gradle/caches"); (( kb > 10240 )) && add_candidate "gradle" "caches Gradle" "$HOME/.gradle/caches" "$kb" "$(newest_age_days "$HOME/.gradle/caches")" \
    "$(verdict_for "$HOME/.gradle/caches" "$CACHE_DAYS" | cut -d'|' -f1)" "$(verdict_for "$HOME/.gradle/caches" "$CACHE_DAYS" | cut -d'|' -f2)" "rm-contents:$HOME/.gradle/caches"; }

# Docker
if have docker && docker info >/dev/null 2>&1; then
  h2 "Docker"
  docker system df 2>/dev/null | sed 's/^/    /'
  rec=$(docker system df --format '{{.Reclaimable}}' 2>/dev/null | head -1)
  add_candidate "Docker" "images/conteneurs/volumes non utilisés" "docker" "0" "-" "PRUDENCE" "récupérable : ${rec:-?} ; docker system prune (sans volumes)" "cmd:docker system prune -f"
fi

# ----------------------------------------------------------------------------
# 4. Modèles IA anciens
# ----------------------------------------------------------------------------
h1 "4. Modèles IA locaux"

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
  info "Store : ~/.ollama/models = $(human $OLL_KB)  · chargés : ${LOADED:-aucun}"
  info "(Ollama ne mémorise pas la dernière utilisation ; l'âge = date du pull / mise à jour.)"
  ollama list 2>/dev/null | awk 'NR>1' | while read -r name id sz unit n u rest; do
    [[ -z "$name" ]] && continue
    case "$unit" in GB) kb=$(( sz * 1048576 )) ;; MB) kb=$(( sz * 1024 )) ;; *) kb=0 ;; esac
    kb=${kb%.*}
    if [[ "$n" == "About" || "$n" == "an" || "$n" == "a" ]]; then days=0; else days=$(rel_to_days "$n" "$u"); fi
    if [[ " $LOADED " == *" $name "* ]]; then
      v="PRUDENCE"; reason="actuellement chargé en mémoire"
    elif (( days >= MODEL_DAYS )); then
      v="PRUDENCE"; reason="pull il y a ${days} j ≥ ${MODEL_DAYS} j ; ollama pull $name pour le ravoir"
    else
      v="MANUEL"; reason="récent (${days} j) — conservé"
    fi
    add_candidate "Modèle Ollama" "$name" "ollama:$name" "$kb" "$days" "$v" "$reason" "cmd:ollama rm $name"
  done
fi

scan_model_root() {  # scan_model_root LABEL RACINE GLOB
  local label="$1" root="$2" d kb age
  [[ -d "$root" ]] || return 0
  h2 "$label"
  for d in "$root"/*(N/); do
    kb=$(du_kb "$d"); (( kb < 51200 )) && continue   # < 50 MiB
    age=$(newest_age_days "$d")
    c=$(conflict_reason "$d")
    if [[ -n "$c" ]]; then v="PRUDENCE"; reason="$c"
    elif (( age >= MODEL_DAYS )); then v="PRUDENCE"; reason="non touché depuis ${age} j ≥ ${MODEL_DAYS} j ; retéléchargeable"
    else v="MANUEL"; reason="récent (${age} j) — conservé"; fi
    add_candidate "$label" "${d:t}" "$d" "$kb" "$age" "$v" "$reason" "rm-path:$d"
  done
}
scan_model_root "Modèle Hugging Face" "$HOME/.cache/huggingface/hub"
scan_model_root "Modèle LM Studio"    "$HOME/.lmstudio/models"
scan_model_root "Modèle LM Studio"    "$HOME/.cache/lm-studio/models"
scan_model_root "Modèle Whisper"      "$HOME/.cache/whisper"
scan_model_root "Modèle Torch"        "$HOME/.cache/torch/hub/checkpoints"

# ----------------------------------------------------------------------------
# 5. Gros volumes divers
# ----------------------------------------------------------------------------
h1 "5. Gros volumes"

# Snapshots Time Machine locaux
if (( SNAP_COUNT > 0 )); then
  tmutil listlocalsnapshots / 2>/dev/null | grep 'com.apple.TimeMachine' | while read -r s; do
    d="${s#com.apple.TimeMachine.}"; d="${d%.local}"
    add_candidate "Snapshot TM" "$d" "snapshot:$d" "0" "-" "PRUDENCE" "taille inconnue avant suppression ; macOS les purge seul si besoin" "cmd:tmutil deletelocalsnapshots $d"
  done
fi

# Corbeille
kb=$(du_kb "$HOME/.Trash")
(( kb > 10240 )) && add_candidate "Corbeille" "~/.Trash" "$HOME/.Trash" "$kb" "$(newest_age_days "$HOME/.Trash")" "PRUDENCE" "irréversible après vidage" "rm-contents:$HOME/.Trash"

# Sauvegardes iOS, pièces jointes Mail
MB="$HOME/Library/Application Support/MobileSync/Backup"
[[ -d "$MB" ]] && { kb=$(du_kb "$MB"); (( kb > 10240 )) && add_candidate "Sauvegardes iOS" "MobileSync/Backup" "$MB" "$kb" "$(newest_age_days "$MB")" "MANUEL" "à gérer dans Finder > appareil > Gérer les sauvegardes" "none"; }
MD="$HOME/Library/Containers/com.apple.mail/Data/Library/Mail Downloads"
[[ -d "$MD" ]] && { kb=$(du_kb "$MD"); (( kb > 10240 )) && add_candidate "Mail" "Mail Downloads (pièces jointes ouvertes)" "$MD" "$kb" "$(newest_age_days "$MD")" "SÛR" "copies temporaires ; les originaux restent dans les messages" "rm-contents:$MD"; }

# node_modules / .venv / target de projets inactifs
h2 "Dépendances de projets inactifs (node_modules, .venv, target)"
find "$HOME" -maxdepth 6 \( -name node_modules -o -name .venv -o -name venv -o -name target \) -type d -prune \
  -not -path "$HOME/Library/*" -not -path "$HOME/.*" 2>/dev/null | while read -r d; do
  proj="${d:h}"
  [[ "${d:t}" == "target" && ! -f "$proj/Cargo.toml" ]] && continue
  skip=0; for ap in "${ACTIVE_PROJECTS[@]}"; do [[ "$proj" == "$ap" || "$proj" == "$ap"/* ]] && skip=1; done
  (( skip )) && continue
  kb=$(du_kb "$d"); (( kb < 51200 )) && continue
  age=$(newest_age_days "$proj")
  (( age < ACTIVE_DAYS )) && continue
  add_candidate "Projet inactif" "${proj/#$HOME/~}/${d:t}" "$d" "$kb" "$age" "PRUDENCE" "projet inactif depuis ${age} j ; réinstallable (npm i / pip / cargo)" "rm-path:$d"
done

# Téléchargements : gros fichiers anciens (liste seulement)
h2 "Téléchargements volumineux de plus de 90 j (liste seulement)"
find "$HOME/Downloads" -maxdepth 1 -type f -size +100M -mtime +90 -print0 2>/dev/null \
  | xargs -0 du -sk 2>/dev/null | sort -rn | head -"$TOP" | while read -r kb f; do
    info "$(printf '%9s' "$(human $kb)")  ${f/#$HOME/~}"
  done
kb=$(find "$HOME/Downloads" -maxdepth 1 -type f -size +100M -mtime +90 -print0 2>/dev/null | xargs -0 du -sk 2>/dev/null | awk '{s+=$1} END{print s+0}')
(( kb > 0 )) && add_candidate "Téléchargements" "~/Downloads : fichiers > 100 Mo et > 90 j" "$HOME/Downloads" "$kb" "90+" "MANUEL" "à trier à la main" "none"

# Données d'applications (informatif : jamais touché, mais souvent là que ça pèse)
h2 "Top $TOP de ~/Library/Application Support et ~/Library/Containers (informatif, MANUEL)"
{ du -xk -d 1 "$HOME/Library/Application Support" 2>/dev/null; du -xk -d 1 "$HOME/Library/Containers" 2>/dev/null; } \
  | sort -rn | awk -F'\t' -v a="$HOME/Library/Application Support" -v c="$HOME/Library/Containers" '$2!=a && $2!=c' | head -"$TOP" | while IFS=$'\t' read -r kb d; do
    info "$(printf '%9s' "$(human $kb)")  ${d/#$HOME/~}"
  done

AC="$HOME/Library/Application Support/com.apple.container"
[[ -d "$AC" ]] && { kb=$(du_kb "$AC"); (( kb > 102400 )) && add_candidate "Apple Container" "images/VM de l'outil 'container' d'Apple" "$AC" "$kb" "$(newest_age_days "$AC")" "MANUEL" "container image prune / container system stop puis suppression manuelle" "none"; }
MW="$HOME/Library/Application Support/MacWhisper"
[[ -d "$MW" ]] && { kb=$(du_kb "$MW"); (( kb > 102400 )) && add_candidate "Modèle MacWhisper" "modèles Whisper téléchargés" "$MW" "$kb" "$(newest_age_days "$MW")" "MANUEL" "à gérer dans MacWhisper > Modèles" "none"; }

# Top dossiers du home (vue d'ensemble)
if (( ! FAST )); then
  h2 "Top $TOP dossiers de ~ (profondeur 2, vue d'ensemble)"
  du -xk -d 2 "$HOME" 2>/dev/null | sort -rn | awk -v home="$HOME" 'NR>1 && NR<=1000 {print}' | head -"$TOP" | while read -r kb d; do
    info "$(printf '%9s' "$(human $kb)")  ${d/#$HOME/~}"
  done
fi

# ----------------------------------------------------------------------------
# 6. Plan de nettoyage
# ----------------------------------------------------------------------------
h1 "6. Plan de nettoyage"

typeset -a ORDER
# tri par taille décroissante
for i in {1..${#CAND_PATH}}; do print -- "${CAND_KB[$i]} $i"; done | sort -rn | awk '{print $2}' | while read -r i; do ORDER+=("$i"); done

describe_action() {
  local kind="${1%%:*}" arg="${1#*:}"
  case "$kind" in
    rm-contents)  print -- "vider ${arg/#$HOME/~}/" ;;
    rm-path)      print -- "supprimer ${arg/#$HOME/~}" ;;
    rm-old-files) print -- "supprimer les fichiers > ${arg##*:} j dans ${${arg%:*}/#$HOME/~}" ;;
    cmd)          print -- "$arg" ;;
    sudo)         print -- "sudo $arg" ;;
    *)            print -- "$1" ;;
  esac
}

SAFE_KB=0 CAUT_KB=0 MAN_KB=0 SAFE_N=0 CAUT_N=0 MAN_N=0
print_group() {  # print_group VERDICT TITRE
  local want="$1" title="$2" i shown=0
  for i in "${ORDER[@]}"; do
    [[ "${CAND_VERDICT[$i]}" == "$want" ]] || continue
    if (( ! shown )); then h2 "$title"; shown=1; fi
    printf "  %-9s  %-16s  %-48s  %s\n" "$(human ${CAND_KB[$i]})" "${CAND_CAT[$i]}" "${CAND_LABEL[$i]:0:48}" "${C_DIM}${CAND_REASON[$i]}${C_RESET}"
    [[ "${CAND_ACTION[$i]}" != "none" ]] && printf "  %-9s  %-16s  ${C_DIM}→ %s${C_RESET}\n" "" "" "$(describe_action "${CAND_ACTION[$i]}")"
  done
  (( shown )) || { h2 "$title"; info "(rien)"; }
}
for i in {1..${#CAND_PATH}}; do
  case "${CAND_VERDICT[$i]}" in
    SÛR)      (( SAFE_KB += CAND_KB[$i] )); (( SAFE_N++ )) ;;
    PRUDENCE) (( CAUT_KB += CAND_KB[$i] )); (( CAUT_N++ )) ;;
    MANUEL)   (( MAN_KB  += CAND_KB[$i] )); (( MAN_N++ )) ;;
  esac
done

print_group "SÛR"      "${C_GREEN}A. SÛR — exécuté en bloc après confirmation (${SAFE_N} éléments, ≈ $(human $SAFE_KB))${C_RESET}"
print_group "PRUDENCE" "${C_YELLOW}B. PRUDENCE — demandé un par un (${CAUT_N} éléments, ≈ $(human $CAUT_KB))${C_RESET}"
print_group "MANUEL"   "${C_DIM}C. MANUEL — jamais touché par le script (${MAN_N} éléments, ≈ $(human $MAN_KB))${C_RESET}"

print
say "${C_BOLD}Résumé${C_RESET} : libérable sans risque ≈ ${C_GREEN}$(human $SAFE_KB)${C_RESET} · avec prudence ≈ ${C_YELLOW}$(human $CAUT_KB)${C_RESET} · à trier à la main ≈ $(human $MAN_KB)"
say "Projets en cours protégés : ${#ACTIVE_PROJECTS} · Spotlight : $( ((SPOT_SUSPECT)) && print -- "${C_RED}SUSPECT${C_RESET}" || print -- "${C_GREEN}sain${C_RESET}" )"

if (( DRY_RUN )); then
  print
  dim "Mode --dry-run : rien n'a été supprimé. Relancez sans --dry-run pour exécuter le plan."
  exit 0
fi

# ----------------------------------------------------------------------------
# 7. Exécution
# ----------------------------------------------------------------------------
h1 "7. Exécution"

run_action() {  # run_action ACTION  -> exécute, 0 si ok
  local a="$1" kind="${1%%:*}" arg="${1#*:}" p days
  case "$kind" in
    rm-contents) p="$arg"; [[ -d "$p" && "$p" == "$HOME"/* ]] || { bad "chemin refusé : $p"; return 1; }
                 find "$p" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null ;;
    rm-path)     p="$arg"; [[ -e "$p" && "$p" == "$HOME"/* && "$p" != "$HOME" ]] || { bad "chemin refusé : $p"; return 1; }
                 rm -rf "$p" ;;
    rm-old-files) p="${arg%:*}"; days="${arg##*:}"
                 find "$p" -type f -mtime +"$days" -delete 2>/dev/null
                 find "$p" -mindepth 1 -type d -empty -delete 2>/dev/null ;;
    cmd)         eval "$arg" ;;
    sudo)        sudo $=arg ;;
    none)        return 0 ;;
    *)           bad "action inconnue : $a"; return 1 ;;
  esac
}

ask() {  # ask "question" -> 0 si oui
  local r
  print -n -- "$1 "
  read -r r
  [[ "$r" == "oui" || "$r" == "o" || "$r" == "y" || "$r" == "yes" ]]
}

FREED_BEFORE=$(df -k "$DATA_VOL" | tail -1 | awk '{print $4}')
DONE_N=0

if (( SAFE_N > 0 )); then
  if (( ASSUME_YES )) || ask "Exécuter les ${SAFE_N} actions SÛRES (≈ $(human $SAFE_KB)) ? Tapez ${C_BOLD}oui${C_RESET} :"; then
    for i in "${ORDER[@]}"; do
      [[ "${CAND_VERDICT[$i]}" == "SÛR" && "${CAND_ACTION[$i]}" != "none" ]] || continue
      print -n -- "  ${CAND_LABEL[$i]:0:60} … "
      if run_action "${CAND_ACTION[$i]}" >> "$LOG_FILE" 2>&1; then print -- "${C_GREEN}ok${C_RESET}"; (( DONE_N++ )); else print -- "${C_RED}échec (voir journal)${C_RESET}"; fi
    done
  else
    info "Actions SÛRES ignorées."
  fi
fi

if (( CAUT_N > 0 )) && [[ -t 0 ]]; then
  print
  say "Actions PRUDENCE — répondez ${C_BOLD}o${C_RESET}ui / ${C_BOLD}N${C_RESET}on / ${C_BOLD}q${C_RESET}uitter pour chacune :"
  for i in "${ORDER[@]}"; do
    [[ "${CAND_VERDICT[$i]}" == "PRUDENCE" && "${CAND_ACTION[$i]}" != "none" ]] || continue
    print -n -- "  [$(human ${CAND_KB[$i]})] ${CAND_CAT[$i]} · ${CAND_LABEL[$i]:0:50} — ${C_DIM}${CAND_REASON[$i]}${C_RESET}  [o/N/q] "
    read -r r
    case "$r" in
      q|Q) break ;;
      o|O|y|Y|oui|yes)
        if run_action "${CAND_ACTION[$i]}" >> "$LOG_FILE" 2>&1; then ok "fait"; (( DONE_N++ )); else bad "échec (voir journal)"; fi ;;
      *) info "ignoré" ;;
    esac
  done
elif (( CAUT_N > 0 )); then
  info "Actions PRUDENCE non proposées (pas de terminal interactif)."
fi

sleep 2
FREED_AFTER=$(df -k "$DATA_VOL" | tail -1 | awk '{print $4}')
FREED=$(( FREED_AFTER - FREED_BEFORE )); (( FREED < 0 )) && FREED=0
print
say "${C_BOLD}Terminé${C_RESET} : ${DONE_N} action(s) exécutée(s) · espace libéré ≈ ${C_GREEN}$(human $FREED)${C_RESET} · libre maintenant : $(human $FREED_AFTER)"
dim "(APFS libère parfois l'espace avec un délai ; les snapshots supprimés se purgent en arrière-plan.)"
dim "Journal complet : $LOG_FILE"
