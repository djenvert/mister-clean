#!/bin/zsh
# =============================================================================
# mister-clean.sh — Audit disque macOS : Spotlight, caches, vieux modèles IA,
#                   gros volumes, protection des projets en cours, plan de
#                   nettoyage (affiché en --dry-run, exécuté après confirmation).
#
# Aide : ./mister-clean.sh --help
#
# Tous les textes affichés (aide comprise) vivent dans les catalogues de
# messages (fonctions messages_fr et messages_en, choisies par --lang ou par
# la locale) ; la logique ne manipule que des clés et des valeurs internes
# indépendantes de la langue (verdicts safe / caution / manual, catégories
# cache_app, xcode…).
# =============================================================================

# Options du shell posées sans « -L » : quand le script est chargé (source)
# par la suite de tests, elles restent en vigueur pour les fonctions appelées.
emulate zsh
setopt null_glob pipe_fail no_nomatch
set -u

VERSION="1.0.0"

# ----------------------------------------------------------------------------
# Catalogue de messages
# ----------------------------------------------------------------------------
# Chaque entrée est un format printf : %s pour les valeurs, %1$s, %2$s… si une
# langue doit les réordonner, %% pour un « % » littéral. Le nombre de
# spécificateurs doit égaler le nombre d'arguments passés par la logique.
# Balises de couleur, remplacées à l'affichage (vides hors terminal) :
#   {bold} {dim} {red} {green} {yellow} {blue} {cyan} {reset}
# Un catalogue d'une autre langue définit exactement les mêmes clés.
typeset -gA MSG

messages_fr() {
  MSG=(
    # --- Aide (--help), affichée telle quelle, sans interprétation printf
    help "$(cat <<'EOF'
=============================================================================
mister-clean.sh — Audit disque macOS : Spotlight, caches, vieux modèles IA,
                  gros volumes, protection des projets en cours, plan de
                  nettoyage (affiché en --dry-run, exécuté après confirmation).

Usage :
  ./mister-clean.sh --dry-run            # audit + plan, aucune suppression
  ./mister-clean.sh                      # audit + plan + confirmation + exécution

Options :
  --dry-run          N'exécute rien, affiche seulement le plan.
  --yes              Exécute les actions SÛRES sans demander (les actions
                     PRUDENCE restent demandées une par une, jamais en --yes).
  --days N           Un cache non modifié depuis N jours est "inutilisé" (30).
  --model-days N     Un modèle non touché depuis N jours est "ancien" (90).
  --active-days N    Un projet modifié depuis N jours est "en cours" (30).
  --top N            Nombre de lignes dans les classements (20).
  --fast             Saute les étapes lentes (journal système, du profonds).
  --skip-spotlight   Saute l'audit Spotlight.
  --lang fr|en       Langue des messages. Par défaut : déduite de LC_ALL,
                     puis LC_MESSAGES, puis LANG (le premier non vide) ;
                     anglais si ce n'est ni du français ni de l'anglais.
  -h, --help         Cette aide.

Verdicts :
  SÛR       Cache régénérable, aucun fichier ouvert, aucun projet en cours
            concerné → supprimé en bloc après la confirmation globale.
  PRUDENCE  Récupérable mais coûteux (modèles, snapshots, caches récents…)
            → demandé item par item.
  MANUEL    Jamais touché par le script (archives Xcode, sauvegardes iOS,
            Téléchargements…) → simplement listé.
=============================================================================
EOF
)"

    # --- Erreurs de démarrage
    err.unknown_option      "Option inconnue : %s (voir --help)"
    err.bad_lang            "Langue non prise en charge : %s (valeurs possibles : fr, en)"
    err.macos_only          "Ce script est conçu pour macOS uniquement."

    # --- Unités de taille (human)
    unit.tib                "%.1f TiB"
    unit.gib                "%.1f GiB"
    unit.mib                "%.0f MiB"
    unit.kib                "%d KiB"

    # --- Verdicts (valeurs internes : safe, caution, manual)
    verdict.safe            "SÛR"
    verdict.caution         "PRUDENCE"
    verdict.manual          "MANUEL"

    # --- Catégories de candidats (valeurs internes après « cat. »)
    cat.spotlight           "Spotlight"
    cat.cache_app           "Cache app"
    cat.cache_cli           "Cache CLI"
    cat.logs                "Journaux"
    cat.xcode               "Xcode"
    cat.simulator           "Simulateur"
    cat.homebrew            "Homebrew"
    cat.npm                 "npm"
    cat.pnpm                "pnpm"
    cat.yarn                "yarn"
    cat.pip                 "pip"
    cat.uv                  "uv"
    cat.cargo               "cargo"
    cat.go                  "go"
    cat.gradle              "gradle"
    cat.docker              "Docker"
    cat.model_ollama        "Modèle Ollama"
    cat.model_huggingface   "Modèle Hugging Face"
    cat.model_lmstudio      "Modèle LM Studio"
    cat.model_whisper       "Modèle Whisper"
    cat.model_torch         "Modèle Torch"
    cat.model_macwhisper    "Modèle MacWhisper"
    cat.tm_snapshot         "Snapshot TM"
    cat.trash               "Corbeille"
    cat.ios_backups         "Sauvegardes iOS"
    cat.mail                "Mail"
    cat.inactive_project    "Projet inactif"
    cat.downloads           "Téléchargements"
    cat.apple_container     "Apple Container"

    # --- En-tête
    header.title            "{bold}{cyan}mister-clean v%s{reset} — %s  %s"
    header.dry_run          "[DRY-RUN]"
    header.system           "macOS %s · %s · journal : %s"
    header.thresholds       "Seuils : cache inutilisé ≥ %s j · modèle ancien ≥ %s j · projet en cours ≤ %s j"

    # --- 0. Disque
    disk.title              "0. État du disque"
    disk.volume             "Volume données : %s utilisés / %s · libre : %s"
    disk.purgeable          "Espace purgeable (macOS peut le libérer seul) : %s"
    disk.snapshots          "Snapshots Time Machine locaux : %s"
    disk.fda_ok             "Accès complet au disque : OK pour ce terminal."
    disk.fda_missing        "Ce terminal n'a PAS l'Accès complet au disque (Réglages > Confidentialité et sécurité)."
    disk.fda_consequence    "Les tests Spotlight par échantillon/sonde seront marqués NON CONCLUANTS, et certains caches ne seront pas vus."

    # --- 1. Projets en cours
    active.title            "1. Projets en cours et fichiers ouverts (filet de sécurité)"
    active.scanning_git     "Dépôts git modifiés depuis %s j…"
    active.scanning_lsof    "Fichiers ouverts par vos processus (lsof)…"
    active.found            "%s projet(s) considéré(s) en cours — rien n'y sera touché :"
    active.none             "Aucun projet actif détecté."
    active.open_files       "%s fichiers ouverts sous ~ (tout candidat contenant l'un d'eux passera en PRUDENCE)."
    active.running_apps     "Apps en cours d'exécution : %s"

    # --- 2. Spotlight
    spot.title              "2. Spotlight — contre-vérification de l'index"
    spot.mdutil.title       "2a. État de l'indexation par volume (mdutil)"
    spot.mdutil.enabled     "%s : %s"
    spot.mdutil.disabled    "%s : %s (volume exclu de Spotlight — pas d'index à nettoyer)"
    spot.mdutil.unreachable "%s : non accessible à ce terminal (%s)"
    spot.mdutil.abnormal    "%s : %s"
    spot.size.title         "2b. Taille des index vs taille des données"
    spot.size.system        "Index système : %s (%s %% des données). Normal : 0,5 – 3 %%."
    spot.size.bloated       "Ratio anormalement élevé → index gonflé/obsolète probable."
    spot.size.no_sudo       "Index système non mesurable sans sudo (Accès complet au disque requis). Relancer avec 'sudo -v' avant si besoin."
    spot.size.user          "Index utilisateur (CoreSpotlight) : %s"
    spot.sample.title       "2c. Contre-vérification n°1 — échantillon de fichiers réels vs index"
    spot.sample.dir         "Dossier échantillonné : %s"
    spot.sample.missing     "absent de l'index : %s"
    spot.sample.inconclusive "NON CONCLUANT : %s / %s absents, mais mdfind est bridé sans Accès complet au disque. Relancez depuis Terminal.app avec l'accès accordé."
    spot.sample.empty       "Aucun fichier échantillonnable dans %s."
    spot.sample.bad         "%s / %s fichiers (%s %%) connus du disque mais inconnus de Spotlight → index incomplet/corrompu."
    spot.sample.warn        "%s / %s fichiers absents de l'index (%s %%) — tolérable, mais à surveiller."
    spot.sample.ok          "%s / %s fichiers absents de l'index (%s %%) — l'index reflète le disque."
    spot.probe.title        "2d. Contre-vérification n°2 — sonde en direct (le démon indexe-t-il encore ?)"
    spot.probe.ok           "Nouveau fichier indexé en %s s — mds fonctionne."
    spot.probe.inconclusive "NON CONCLUANT : sonde invisible, mais mdfind est bridé pour ce terminal (voir plus haut)."
    spot.probe.bad          "Nouveau fichier toujours non indexé après 15 s → indexation bloquée ou en panne."
    spot.log.title          "2e. Contre-vérification n°3 — journal système et processus mds"
    spot.log.skipped        "(--fast) journal système ignoré."
    spot.log.bad            "%s message(s) évoquant une corruption de l'index dans les 2 dernières heures :"
    spot.log.ok             "Aucun message de corruption dans le journal mds (2 h)."
    spot.cpu.high           "mds/mdworker consomment %s %% CPU : réindexation en cours ou boucle."
    spot.cpu.info           "CPU cumulé mds/mdworker : %s %%"
    spot.verdict.title      "2f. Verdict Spotlight"
    spot.verdict.inconclusive "Aucun signe de corruption sur les tests disponibles, mais 2 tests sur 3 sont NON CONCLUANTS sans Accès complet au disque."
    spot.verdict.healthy    "Index SAIN : les {bold}3 contre-vérifications{reset} concordent (échantillon, sonde, journal). Pas de reconstruction nécessaire."
    spot.verdict.suspect    "Index SUSPECT (%s indice(s)) :"
    spot.finding.mdutil     "mdutil signale un état anormal sur %s : %s"
    spot.finding.ratio      "index système = %s %% des données (attendu < 3 %%)"
    spot.finding.sample     "%s/%s fichiers échantillonnés absents de l'index"
    spot.finding.probe      "sonde non indexée après 15 s"
    spot.finding.log        "%s messages de corruption dans le journal mds"

    # --- Raisons de verdict communes
    reason.in_active_project "dans le projet en cours %s"
    reason.contains_active_project "contient le projet en cours %s"
    reason.open_file        "fichier ouvert par un processus : %s"
    reason.recent           "modifié il y a moins de %s j (encore utilisé, sera régénéré)"
    reason.unused           "non modifié depuis ≥ %s j, régénérable"
    reason.redownloaded     "retéléchargé à la demande"
    reason.sort_by_hand     "à trier à la main"

    # --- Candidats : libellés et raisons, par source
    spotlight.rebuild.label "Reconstruire l'index Spotlight (mdutil -E /)"
    spotlight.rebuild.reason "index suspect ; la reconstruction efface l'index gonflé puis réindexe (CPU pendant 1–3 h)"

    caches.title            "3. Scan des caches"
    caches.apple.reason     "cache Apple ; régénéré mais parfois volumineux à reconstruire (ex. Photos, iCloud)"
    caches.icloud.reason    "lié à iCloud"
    logs.label              "%s (fichiers > %s j)"
    logs.reason             "journaux anciens, sans valeur sauf diagnostic en cours"

    dev.title               "Outils développeur"
    xcode.open.reason       "Xcode est ouvert : fermez-le avant"
    xcode.derived.label     "DerivedData (builds intermédiaires)"
    xcode.devicesupport.label "%s (symboles d'anciens OS)"
    xcode.devicesupport.reason "retéléchargé à la prochaine connexion d'un appareil"
    xcode.archives.label    "Archives (.xcarchive + dSYM)"
    xcode.archives.reason   "contient les symboles des versions publiées : à trier à la main"
    sim.unavailable.label   "Simulateurs indisponibles (runtime désinstallé)"
    sim.unavailable.reason  "xcrun simctl delete unavailable ne retire que les simulateurs orphelins"

    pkg.title               "Gestionnaires de paquets"
    homebrew.label          "cache des téléchargements + vieilles versions"
    homebrew.reason         "brew cleanup --prune=all -s retire bouteilles et téléchargements obsolètes"
    npm.label               "cache npm (_cacache)"
    pnpm.label              "store pnpm (paquets orphelins)"
    pnpm.reason             "pnpm store prune ne retire que les paquets non référencés"
    yarn.label              "cache yarn"
    pip.label               "cache pip"
    uv.label                "cache uv"
    uv.reason               "uv cache prune ne retire que l'inutilisé"
    cargo.label             "registry Rust (sources + crates)"
    cargo.reason            "retéléchargé au prochain build, mais lent hors-ligne"
    go.label                "cache modules Go"
    go.reason               "retéléchargé au prochain build"
    gradle.label            "caches Gradle"
    docker.title            "Docker"
    docker.label            "images/conteneurs/volumes non utilisés"
    docker.reason           "récupérable : %s ; docker system prune (sans volumes)"

    models.title            "4. Modèles IA locaux"
    ollama.title            "Ollama"
    ollama.store            "Store : ~/.ollama/models = %s  · chargés : %s"
    ollama.none_loaded      "aucun"
    ollama.age_note         "(Ollama ne mémorise pas la dernière utilisation ; l'âge = date du pull / mise à jour.)"
    model.loaded.reason     "actuellement chargé en mémoire"
    model.ollama_old.reason "pull il y a %s j ≥ %s j ; ollama pull %s pour le ravoir"
    model.old.reason        "non touché depuis %s j ≥ %s j ; retéléchargeable"
    model.recent.reason     "récent (%s j) — conservé"

    big.title               "5. Gros volumes"
    snapshot.reason         "taille inconnue avant suppression ; macOS les purge seul si besoin"
    trash.reason            "irréversible après vidage"
    ios_backups.reason      "à gérer dans Finder > appareil > Gérer les sauvegardes"
    mail.label              "Mail Downloads (pièces jointes ouvertes)"
    mail.reason             "copies temporaires ; les originaux restent dans les messages"
    deps.title              "Dépendances de projets inactifs (node_modules, .venv, target)"
    deps.reason             "projet inactif depuis %s j ; réinstallable (npm i / pip / cargo)"
    downloads.title         "Téléchargements volumineux de plus de 90 j (liste seulement)"
    downloads.label         "~/Downloads : fichiers > 100 Mo et > 90 j"
    appdata.title           "Top %s de ~/Library/Application Support et ~/Library/Containers (informatif, MANUEL)"
    apple_container.label   "images/VM de l'outil 'container' d'Apple"
    apple_container.reason  "container image prune / container system stop puis suppression manuelle"
    macwhisper.label        "modèles Whisper téléchargés"
    macwhisper.reason       "à gérer dans MacWhisper > Modèles"
    home.title              "Top %s dossiers de ~ (profondeur 2, vue d'ensemble)"

    # --- 6. Plan
    plan.title              "6. Plan de nettoyage"
    action.rm_contents      "vider %s/"
    action.rm_path          "supprimer %s"
    action.rm_old_files     "supprimer les fichiers > %s j dans %s"
    plan.group.safe         "A. %s — exécuté en bloc après confirmation (%s éléments, ≈ %s)"
    plan.group.caution      "B. %s — demandé un par un (%s éléments, ≈ %s)"
    plan.group.manual       "C. %s — jamais touché par le script (%s éléments, ≈ %s)"
    plan.group.empty        "(rien)"
    plan.summary            "{bold}Résumé{reset} : libérable sans risque ≈ {green}%s{reset} · avec prudence ≈ {yellow}%s{reset} · à trier à la main ≈ %s"
    plan.status             "Projets en cours protégés : %s · Spotlight : %s"
    plan.spotlight.suspect  "SUSPECT"
    plan.spotlight.healthy  "sain"
    plan.dry_run            "Mode --dry-run : rien n'a été supprimé. Relancez sans --dry-run pour exécuter le plan."

    # --- 7. Exécution
    exec.title              "7. Exécution"
    exec.path_refused       "chemin refusé : %s"
    exec.unknown_action     "action inconnue : %s"
    exec.confirm_safe       "Exécuter les %s actions SÛRES (≈ %s) ? Tapez {bold}oui{reset} :"
    exec.ok                 "ok"
    exec.failed             "échec (voir journal)"
    exec.safe_skipped       "Actions SÛRES ignorées."
    exec.caution_intro      "Actions PRUDENCE — répondez {bold}o{reset}ui / {bold}N{reset}on / {bold}q{reset}uitter pour chacune :"
    exec.caution_choices    "[o/N/q]"
    exec.done               "fait"
    exec.skipped            "ignoré"
    exec.caution_not_offered "Actions PRUDENCE non proposées (pas de terminal interactif)."
    exec.summary            "{bold}Terminé{reset} : %s action(s) exécutée(s) · espace libéré ≈ {green}%s{reset} · libre maintenant : %s"
    exec.apfs_note          "(APFS libère parfois l'espace avec un délai ; les snapshots supprimés se purgent en arrière-plan.)"
    exec.log                "Journal complet : %s"

    # --- Réponses acceptées aux confirmations (mots séparés par des espaces,
    #     comparés à l'identique, casse comprise)
    answer.confirm_yes      "oui o y yes"
    answer.item_yes         "o O y Y oui yes"
    answer.item_quit        "q Q"
  )
}

messages_en() {
  MSG=(
    # --- Help (--help), printed as is, no printf interpretation
    help "$(cat <<'EOF'
=============================================================================
mister-clean.sh — macOS disk audit: Spotlight, caches, old AI models,
                  large folders, protection of active projects, and a
                  cleanup plan (printed with --dry-run, executed after
                  confirmation otherwise).

Usage:
  ./mister-clean.sh --dry-run            # audit + plan, nothing deleted
  ./mister-clean.sh                      # audit + plan + confirmation + execution

Options:
  --dry-run          Execute nothing, only print the plan.
  --yes              Run SAFE actions without asking (CAUTION actions are
                     still asked one by one, never auto-accepted).
  --days N           A cache untouched for N days counts as "unused" (30).
  --model-days N     A model untouched for N days counts as "old" (90).
  --active-days N    A project modified within N days counts as "active" (30).
  --top N            Number of rows in the rankings (20).
  --fast             Skip slow steps (system log, deep du).
  --skip-spotlight   Skip the Spotlight audit.
  --lang fr|en       Message language. Default: taken from LC_ALL, then
                     LC_MESSAGES, then LANG (first non-empty one);
                     English if that is neither French nor English.
  -h, --help         This help.

Verdicts:
  SAFE      Regenerable cache, no open file, no active project involved
            → deleted in one batch after the global confirmation.
  CAUTION   Recoverable but costly (models, snapshots, recent caches…)
            → asked item by item.
  MANUAL    Never touched by the script (Xcode archives, iOS backups,
            Downloads…) → only listed.
=============================================================================
EOF
)"

    # --- Startup errors
    err.unknown_option      "Unknown option: %s (see --help)"
    err.bad_lang            "Unsupported language: %s (expected fr or en)"
    err.macos_only          "This script is designed for macOS only."

    # --- Size units (human)
    unit.tib                "%.1f TiB"
    unit.gib                "%.1f GiB"
    unit.mib                "%.0f MiB"
    unit.kib                "%d KiB"

    # --- Verdicts (internal values: safe, caution, manual)
    verdict.safe            "SAFE"
    verdict.caution         "CAUTION"
    verdict.manual          "MANUAL"

    # --- Candidate categories (internal values after "cat.")
    cat.spotlight           "Spotlight"
    cat.cache_app           "App cache"
    cat.cache_cli           "CLI cache"
    cat.logs                "Logs"
    cat.xcode               "Xcode"
    cat.simulator           "Simulator"
    cat.homebrew            "Homebrew"
    cat.npm                 "npm"
    cat.pnpm                "pnpm"
    cat.yarn                "yarn"
    cat.pip                 "pip"
    cat.uv                  "uv"
    cat.cargo               "cargo"
    cat.go                  "go"
    cat.gradle              "gradle"
    cat.docker              "Docker"
    cat.model_ollama        "Ollama model"
    cat.model_huggingface   "Hugging Face model"
    cat.model_lmstudio      "LM Studio model"
    cat.model_whisper       "Whisper model"
    cat.model_torch         "Torch model"
    cat.model_macwhisper    "MacWhisper model"
    cat.tm_snapshot         "TM snapshot"
    cat.trash               "Trash"
    cat.ios_backups         "iOS backups"
    cat.mail                "Mail"
    cat.inactive_project    "Inactive project"
    cat.downloads           "Downloads"
    cat.apple_container     "Apple Container"

    # --- Header
    header.title            "{bold}{cyan}mister-clean v%s{reset} — %s  %s"
    header.dry_run          "[DRY-RUN]"
    header.system           "macOS %s · %s · log: %s"
    header.thresholds       "Thresholds: unused cache ≥ %s d · old model ≥ %s d · active project ≤ %s d"

    # --- 0. Disk
    disk.title              "0. Disk state"
    disk.volume             "Data volume: %s used / %s · free: %s"
    disk.purgeable          "Purgeable space (macOS can free it by itself): %s"
    disk.snapshots          "Local Time Machine snapshots: %s"
    disk.fda_ok             "Full Disk Access: OK for this terminal."
    disk.fda_missing        "This terminal does NOT have Full Disk Access (System Settings > Privacy & Security)."
    disk.fda_consequence    "The Spotlight sample/probe tests will be marked INCONCLUSIVE, and some caches will not be visible."

    # --- 1. Active projects
    active.title            "1. Active projects and open files (safety net)"
    active.scanning_git     "Git repositories modified within %s d…"
    active.scanning_lsof    "Files open by your processes (lsof)…"
    active.found            "%s project(s) considered active — nothing will be touched there:"
    active.none             "No active project detected."
    active.open_files       "%s open files under ~ (any candidate containing one of them is downgraded to CAUTION)."
    active.running_apps     "Running apps: %s"

    # --- 2. Spotlight
    spot.title              "2. Spotlight — index cross-verification"
    spot.mdutil.title       "2a. Indexing state per volume (mdutil)"
    spot.mdutil.enabled     "%s: %s"
    spot.mdutil.disabled    "%s: %s (volume excluded from Spotlight — no index to clean)"
    spot.mdutil.unreachable "%s: not reachable from this terminal (%s)"
    spot.mdutil.abnormal    "%s: %s"
    spot.size.title         "2b. Index size vs data size"
    spot.size.system        "System index: %s (%s %% of data). Normal: 0.5 – 3 %%."
    spot.size.bloated       "Abnormally high ratio → bloated/stale index likely."
    spot.size.no_sudo       "System index not measurable without sudo (Full Disk Access required). Run 'sudo -v' first if needed."
    spot.size.user          "User index (CoreSpotlight): %s"
    spot.sample.title       "2c. Cross-check #1 — sample of real files vs index"
    spot.sample.dir         "Sampled folder: %s"
    spot.sample.missing     "missing from index: %s"
    spot.sample.inconclusive "INCONCLUSIVE: %s / %s missing, but mdfind is restricted without Full Disk Access. Rerun from Terminal.app with access granted."
    spot.sample.empty       "No file to sample in %s."
    spot.sample.bad         "%s / %s files (%s %%) exist on disk but are unknown to Spotlight → incomplete/corrupted index."
    spot.sample.warn        "%s / %s files missing from the index (%s %%) — tolerable, but worth watching."
    spot.sample.ok          "%s / %s files missing from the index (%s %%) — the index reflects the disk."
    spot.probe.title        "2d. Cross-check #2 — live probe (is the daemon still indexing?)"
    spot.probe.ok           "New file indexed in %s s — mds is working."
    spot.probe.inconclusive "INCONCLUSIVE: probe not visible, but mdfind is restricted for this terminal (see above)."
    spot.probe.bad          "New file still not indexed after 15 s → indexing stalled or broken."
    spot.log.title          "2e. Cross-check #3 — system log and mds processes"
    spot.log.skipped        "(--fast) system log skipped."
    spot.log.bad            "%s message(s) hinting at index corruption in the last 2 hours:"
    spot.log.ok             "No corruption message in the mds log (2 h)."
    spot.cpu.high           "mds/mdworker use %s %% CPU: reindexing in progress or stuck in a loop."
    spot.cpu.info           "Combined mds/mdworker CPU: %s %%"
    spot.verdict.title      "2f. Spotlight verdict"
    spot.verdict.inconclusive "No sign of corruption on the available tests, but 2 of 3 tests are INCONCLUSIVE without Full Disk Access."
    spot.verdict.healthy    "Index HEALTHY: the {bold}3 cross-checks{reset} agree (sample, probe, log). No rebuild needed."
    spot.verdict.suspect    "Index SUSPECT (%s clue(s)):"
    spot.finding.mdutil     "mdutil reports an abnormal state on %s: %s"
    spot.finding.ratio      "system index = %s %% of data (expected < 3 %%)"
    spot.finding.sample     "%s/%s sampled files missing from the index"
    spot.finding.probe      "probe not indexed after 15 s"
    spot.finding.log        "%s corruption messages in the mds log"

    # --- Common verdict reasons
    reason.in_active_project "inside active project %s"
    reason.contains_active_project "contains active project %s"
    reason.open_file        "file open by a process: %s"
    reason.recent           "modified less than %s d ago (still in use, will be regenerated)"
    reason.unused           "untouched for ≥ %s d, regenerable"
    reason.redownloaded     "re-downloaded on demand"
    reason.sort_by_hand     "sort by hand"

    # --- Candidates: labels and reasons, by source
    spotlight.rebuild.label "Rebuild the Spotlight index (mdutil -E /)"
    spotlight.rebuild.reason "suspect index; the rebuild wipes the bloated index then reindexes (CPU for 1–3 h)"

    caches.title            "3. Cache scan"
    caches.apple.reason     "Apple cache; regenerated but sometimes costly to rebuild (e.g. Photos, iCloud)"
    caches.icloud.reason    "tied to iCloud"
    logs.label              "%s (files > %s d)"
    logs.reason             "old logs, worthless unless a diagnosis is in progress"

    dev.title               "Developer tools"
    xcode.open.reason       "Xcode is open: quit it first"
    xcode.derived.label     "DerivedData (intermediate builds)"
    xcode.devicesupport.label "%s (symbols of old OS versions)"
    xcode.devicesupport.reason "re-downloaded the next time a device is plugged in"
    xcode.archives.label    "Archives (.xcarchive + dSYM)"
    xcode.archives.reason   "holds the symbols of shipped releases: sort by hand"
    sim.unavailable.label   "Unavailable simulators (runtime uninstalled)"
    sim.unavailable.reason  "xcrun simctl delete unavailable only removes orphaned simulators"

    pkg.title               "Package managers"
    homebrew.label          "download cache + old versions"
    homebrew.reason         "brew cleanup --prune=all -s removes stale bottles and downloads"
    npm.label               "npm cache (_cacache)"
    pnpm.label              "pnpm store (orphaned packages)"
    pnpm.reason             "pnpm store prune only removes unreferenced packages"
    yarn.label              "yarn cache"
    pip.label               "pip cache"
    uv.label                "uv cache"
    uv.reason               "uv cache prune only removes unused entries"
    cargo.label             "Rust registry (sources + crates)"
    cargo.reason            "re-downloaded on the next build, but slow when offline"
    go.label                "Go module cache"
    go.reason               "re-downloaded on the next build"
    gradle.label            "Gradle caches"
    docker.title            "Docker"
    docker.label            "unused images/containers/volumes"
    docker.reason           "reclaimable: %s; docker system prune (volumes kept)"

    models.title            "4. Local AI models"
    ollama.title            "Ollama"
    ollama.store            "Store: ~/.ollama/models = %s  · loaded: %s"
    ollama.none_loaded      "none"
    ollama.age_note         "(Ollama does not track last use; age = date of pull / update.)"
    model.loaded.reason     "currently loaded in memory"
    model.ollama_old.reason "pulled %s d ago ≥ %s d; ollama pull %s to get it back"
    model.old.reason        "untouched for %s d ≥ %s d; re-downloadable"
    model.recent.reason     "recent (%s d) — kept"

    big.title               "5. Large folders"
    snapshot.reason         "size unknown before deletion; macOS purges them on its own when needed"
    trash.reason            "irreversible once emptied"
    ios_backups.reason      "manage in Finder > device > Manage Backups"
    mail.label              "Mail Downloads (opened attachments)"
    mail.reason             "temporary copies; the originals stay in the messages"
    deps.title              "Dependencies of inactive projects (node_modules, .venv, target)"
    deps.reason             "project inactive for %s d; reinstallable (npm i / pip / cargo)"
    downloads.title         "Large downloads older than 90 d (list only)"
    downloads.label         "~/Downloads: files > 100 MB and > 90 d"
    appdata.title           "Top %s of ~/Library/Application Support and ~/Library/Containers (informational, MANUAL)"
    apple_container.label   "images/VMs of Apple's 'container' tool"
    apple_container.reason  "container image prune / container system stop, then delete by hand"
    macwhisper.label        "downloaded Whisper models"
    macwhisper.reason       "manage in MacWhisper > Models"
    home.title              "Top %s folders of ~ (depth 2, overview)"

    # --- 6. Plan
    plan.title              "6. Cleanup plan"
    action.rm_contents      "empty %s/"
    action.rm_path          "delete %s"
    action.rm_old_files     "delete files > %s d in %s"
    plan.group.safe         "A. %s — run in one batch after confirmation (%s items, ≈ %s)"
    plan.group.caution      "B. %s — asked one by one (%s items, ≈ %s)"
    plan.group.manual       "C. %s — never touched by the script (%s items, ≈ %s)"
    plan.group.empty        "(nothing)"
    plan.summary            "{bold}Summary{reset}: safely reclaimable ≈ {green}%s{reset} · with caution ≈ {yellow}%s{reset} · to sort by hand ≈ %s"
    plan.status             "Active projects protected: %s · Spotlight: %s"
    plan.spotlight.suspect  "SUSPECT"
    plan.spotlight.healthy  "healthy"
    plan.dry_run            "--dry-run mode: nothing was deleted. Rerun without --dry-run to execute the plan."

    # --- 7. Execution
    exec.title              "7. Execution"
    exec.path_refused       "path refused: %s"
    exec.unknown_action     "unknown action: %s"
    exec.confirm_safe       "Run the %s SAFE actions (≈ %s)? Type {bold}yes{reset}:"
    exec.ok                 "ok"
    exec.failed             "failed (see log)"
    exec.safe_skipped       "SAFE actions skipped."
    exec.caution_intro      "CAUTION actions — answer {bold}y{reset}es / {bold}N{reset}o / {bold}q{reset}uit for each one:"
    exec.caution_choices    "[y/N/q]"
    exec.done               "done"
    exec.skipped            "skipped"
    exec.caution_not_offered "CAUTION actions not offered (no interactive terminal)."
    exec.summary            "{bold}Done{reset}: %s action(s) executed · space freed ≈ {green}%s{reset} · free now: %s"
    exec.apfs_note          "(APFS sometimes frees space with a delay; deleted snapshots are purged in the background.)"
    exec.log                "Full log: %s"

    # --- Accepted answers to the prompts (space-separated words,
    #     compared exactly, case included)
    answer.confirm_yes      "yes y"
    answer.item_yes         "y Y yes"
    answer.item_quit        "q Q"
  )
}

# m CLÉ [ARGS…] : écrit le message CLÉ formaté avec ARGS, sans saut de ligne.
# Une clé absente du catalogue s'affiche « [clé] » plutôt que de faire échouer le script.
m() {
  local key="$1" fmt; shift
  fmt="${MSG[$key]-[$key]}"
  fmt="${fmt//\{bold\}/${C_BOLD-}}"
  fmt="${fmt//\{dim\}/${C_DIM-}}"
  fmt="${fmt//\{red\}/${C_RED-}}"
  fmt="${fmt//\{green\}/${C_GREEN-}}"
  fmt="${fmt//\{yellow\}/${C_YELLOW-}}"
  fmt="${fmt//\{blue\}/${C_BLUE-}}"
  fmt="${fmt//\{cyan\}/${C_CYAN-}}"
  fmt="${fmt//\{reset\}/${C_RESET-}}"
  printf -- "$fmt" "$@"
}

# answer_in CLÉ RÉPONSE : 0 si RÉPONSE fait partie de la liste de mots CLÉ.
answer_in() {
  local -a words; words=(${=MSG[$1]-})
  (( ${words[(Ie)$2]} ))
}

# ----------------------------------------------------------------------------
# Langue
# ----------------------------------------------------------------------------
# --lang fr|en l'emporte. Sinon, la langue vient du premier non vide de
# LC_ALL, LC_MESSAGES, LANG (ordre de priorité POSIX des locales) : fr, fr_*
# ou fr.* → fr ; tout le reste → en. Repli : en (aucune variable, C, POSIX,
# autre langue).
# --lang est lu avant les autres options, pour que --help et « Option
# inconnue » s'affichent déjà dans la bonne langue, quel que soit l'ordre.
lang_from_env() {
  case "${LC_ALL:-${LC_MESSAGES:-${LANG:-}}}" in
    fr|fr_*|fr.*) print fr ;;
    *)            print en ;;
  esac
}

# Catalogue par défaut dès le chargement ; parse_args le remplace si --lang
# en demande un autre.
UI_LANG="$(lang_from_env)"
messages_$UI_LANG

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

usage() { print -r -- "${MSG[help]}"; exit 0; }

# parse_args ARGS… : lit les options de la ligne de commande dans les variables
# ci-dessus. --lang est lu en premier, pour que --help et « Option inconnue »
# s'affichent déjà dans la bonne langue, quel que soit l'ordre (la dernière
# occurrence l'emporte).
parse_args() {
  local i
  for (( i = 1; i <= $#; i++ )); do
    [[ "${argv[i]}" == --lang ]] || continue
    case "${argv[i+1]-}" in
      fr|en) UI_LANG="${argv[i+1]}"; (( i++ )) ;;
      *) messages_$UI_LANG; print -u2 -- "$(m err.bad_lang "${argv[i+1]-}")"; exit 2 ;;
    esac
  done
  messages_$UI_LANG

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
      --lang)           shift ;;   # déjà lue et validée plus haut
      -h|--help)        usage ;;
      *) print -u2 -- "$(m err.unknown_option "$1")"; exit 2 ;;
    esac
    shift
  done
}

# ----------------------------------------------------------------------------
# Sortie, journal, couleurs
# ----------------------------------------------------------------------------
# Sans terminal (et tant que setup_output n'a pas tourné) : pas de couleurs.
C_RESET=""; C_BOLD=""; C_DIM=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_CYAN=""

# setup_output : journal, répertoire temporaire, couleurs si terminal, et
# duplication de toute la sortie vers le journal.
setup_output() {
  LOG_DIR="$HOME/Library/Logs/mister-clean"
  mkdir -p "$LOG_DIR"
  RUN_ID="$(date +%Y%m%d-%H%M%S)"
  LOG_FILE="$LOG_DIR/run-$RUN_ID.log"
  # Modèle explicite plutôt que « mktemp -t », qui ignore TMPDIR sur macOS.
  TMP="$(mktemp -d "${${TMPDIR:-/tmp}%/}/mister-clean.XXXXXXXXXX")"   # supprimé à la sortie (trap posé avant main)

  if [[ -t 1 ]]; then
    C_RESET=$'\e[0m'; C_BOLD=$'\e[1m'; C_DIM=$'\e[2m'
    C_RED=$'\e[31m'; C_GREEN=$'\e[32m'; C_YELLOW=$'\e[33m'; C_BLUE=$'\e[34m'; C_CYAN=$'\e[36m'
  fi

  # Tout ce qui est affiché est aussi journalisé (sans les codes couleur).
  exec > >(tee >(sed 's/\x1b\[[0-9;]*m//g' >> "$LOG_FILE")) 2>&1
}

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
  if (( kb >= 1073741824 )); then m unit.tib $(( kb / 1073741824.0 ))
  elif (( kb >= 1048576 ));  then m unit.gib $(( kb / 1048576.0 ))
  elif (( kb >= 1024 ));     then m unit.mib $(( kb / 1024.0 ))
  else m unit.kib $kb; fi
}

du_kb() {  # taille d'un chemin en KiB (0 si absent)
  [[ -e "$1" ]] || { print 0; return; }
  local r
  r=$(du -sk "$1" 2>/dev/null | cut -f1)
  print -- "${r:-0}"
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
# CAND_CAT    : clé de catégorie (libellé : MSG[cat.<clé>])
# CAND_VERDICT: safe | caution | manual (libellé : MSG[verdict.<valeur>])
# CAND_LABEL, CAND_REASON : textes déjà rendus depuis le catalogue
#
# Le filet de sécurité vit ici, pas dans les scans : un scan propose un chemin
# et le verdict qu'il souhaite ; add_candidate rétrograde en caution tout
# candidat qui touche un projet en cours ou un fichier ouvert (voir
# conflict_reason). Un nouveau scan ne peut donc pas l'oublier.
typeset -ga CAND_CAT CAND_LABEL CAND_PATH CAND_KB CAND_AGE CAND_VERDICT CAND_REASON CAND_ACTION
# Rempli par audit_active : projets en cours, fichiers ouverts sous ~ (chemins absolus).
typeset -ga OPEN_FILES ACTIVE_PROJECTS

# add_candidate CAT LABEL PATH KB AGE VERDICT RAISON ACTION
# VERDICT et RAISON sont ceux que le scan souhaite. Si PATH est en conflit
# (projet en cours, fichier ouvert), un candidat safe ou caution entre en
# caution avec la raison du conflit ; un candidat manual reste manual (le
# script n'y touche jamais).
add_candidate() {
  local verdict="$6" reason="$7" c
  if [[ "$verdict" != manual ]]; then
    c="$(conflict_reason "$3")"
    [[ -n "$c" ]] && { verdict=caution; reason="$c"; }
  fi
  CAND_CAT+=("$1"); CAND_LABEL+=("$2"); CAND_PATH+=("$3"); CAND_KB+=("$4")
  CAND_AGE+=("$5"); CAND_VERDICT+=("$verdict"); CAND_REASON+=("$reason"); CAND_ACTION+=("$8")
}

# conflict_reason PATH : raison pour laquelle PATH touche un projet en cours
# (PATH dans le projet, ou le projet dans PATH) ou un fichier ouvert (PATH
# lui-même ou un fichier dessous). N'affiche rien s'il n'y a pas de conflit,
# ni si PATH n'est pas un chemin (docker, ollama:…, snapshot:…).
conflict_reason() {
  local p="$1" proj f
  [[ "$p" == /* ]] || return 0
  for proj in "${ACTIVE_PROJECTS[@]}"; do
    if [[ "$p" == "$proj" || "$p" == "$proj"/* ]]; then
      print -r -- "$(m reason.in_active_project "$proj")"; return
    elif [[ "$proj" == "$p"/* ]]; then
      print -r -- "$(m reason.contains_active_project "$proj")"; return
    fi
  done
  f="${OPEN_FILES[(r)${(b)p}(|/*)]-}"
  [[ -z "$f" ]] && return 0
  [[ "$f" == "$p" ]] && f="${f:t}" || f="${f#$p/}"
  print -r -- "$(m reason.open_file "$f")"
}

# Verdict souhaité selon l'âge (les conflits sont l'affaire du registre).
# verdict_for PATH DAYS_THRESHOLD "raison si caution forcée"  ->  "VERDICT|raison"
verdict_for() {
  local p="$1" days="$2" forced="${3:-}"
  if [[ -n "$forced" ]]; then print -- "caution|$forced"; return; fi
  if is_recent "$p" "$days"; then
    print -- "caution|$(m reason.recent "$days")"
  else
    print -- "safe|$(m reason.unused "$days")"
  fi
}

# ----------------------------------------------------------------------------
# En-tête
# ----------------------------------------------------------------------------
audit_disk() {
  print -r -- "$(m header.title "$VERSION" "$(date '+%Y-%m-%d %H:%M')" "$( ((DRY_RUN)) && m header.dry_run )")"
  dim "$(m header.system "$(sw_vers -productVersion)" "$(uname -m)" "$LOG_FILE")"
  dim "$(m header.thresholds "$CACHE_DAYS" "$MODEL_DAYS" "$ACTIVE_DAYS")"

  h1 "$(m disk.title)"
  DATA_VOL="/System/Volumes/Data"
  [[ -d "$DATA_VOL" ]] || DATA_VOL="/"
  DF_LINE=$(df -k "$DATA_VOL" | tail -1)
  DISK_TOTAL_KB=$(print -- "$DF_LINE" | awk '{print $2}')
  DISK_USED_KB=$(print -- "$DF_LINE" | awk '{print $3}')
  DISK_FREE_KB=$(print -- "$DF_LINE" | awk '{print $4}')
  info "$(m disk.volume "$(human $DISK_USED_KB)" "$(human $DISK_TOTAL_KB)" "$(human $DISK_FREE_KB)")"
  PURGEABLE=$(diskutil info "$DATA_VOL" 2>/dev/null | awk -F: '/Purgeable/ {gsub(/^ +/,"",$2); print $2}' | head -1)
  [[ -n "$PURGEABLE" ]] && info "$(m disk.purgeable "$PURGEABLE")"
  SNAP_COUNT=$(tmutil listlocalsnapshots / 2>/dev/null | grep -c 'com.apple.TimeMachine')
  info "$(m disk.snapshots "$SNAP_COUNT")"

  # Accès complet au disque (TCC) : sans lui, ~/Documents, ~/Desktop et les résultats
  # de mdfind sont masqués à ce terminal → les contre-vérifications Spotlight seraient faussées.
  TCC_OK=1
  if ! ls "$HOME/Desktop" >/dev/null 2>&1 && [[ -d "$HOME/Desktop" ]]; then TCC_OK=0; fi
  if (( TCC_OK )); then ok "$(m disk.fda_ok)"
  else
    warn "$(m disk.fda_missing)"
    warn "$(m disk.fda_consequence)"
  fi
}

# ----------------------------------------------------------------------------
# 1. Projets en cours & fichiers ouverts  (le filet de sécurité)
# ----------------------------------------------------------------------------
audit_active() {
  h1 "$(m active.title)"

  info "$(m active.scanning_git "$ACTIVE_DAYS")"
  while IFS= read -r gitdir; do
    proj="${gitdir:h}"
    # Un dépôt à la racine de ~ (dotfiles) protégerait tout ~ : on l'ignore,
    # comme les répertoires de travail égaux à ~ plus bas.
    [[ "$proj" == "$HOME" ]] && continue
    if [[ -n "$(find "$proj" -maxdepth 4 -type f -mtime -"$ACTIVE_DAYS" \
          -not -path '*/node_modules/*' -not -path '*/.git/*' -print -quit 2>/dev/null)" ]]; then
      ACTIVE_PROJECTS+=("$proj")
    fi
  done < <(find "$HOME" -maxdepth 5 -name .git -type d \
            -not -path "$HOME/Library/*" -not -path "$HOME/.Trash/*" \
            -not -path '*/node_modules/*' -not -path "$HOME/.*/*" 2>/dev/null)

  info "$(m active.scanning_lsof)"
  OPEN_FILES=(${(f)"$(lsof -n -u "$USER" -F n 2>/dev/null | sed -n 's/^n//p' | grep "^$HOME/" | sort -u)"})
  # Le journal de cette exécution est forcément ouvert : il ne protège rien.
  OPEN_FILES=(${OPEN_FILES:#${(b)LOG_DIR}/*})
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
    ok "$(m active.found "${#ACTIVE_PROJECTS}")"
    for p in "${ACTIVE_PROJECTS[@]}"; do info "  ${p/#$HOME/~}"; done
  else
    ok "$(m active.none)"
  fi
  info "$(m active.open_files "${#OPEN_FILES}")"

  typeset -a RUNNING_APPS
  for app in Xcode ollama "Docker" "Code" "Cursor" "Google Chrome" Safari Arc Firefox Slack Spotify "LM Studio"; do
    is_running "$app" && RUNNING_APPS+=("$app")
  done
  (( ${#RUNNING_APPS} )) && info "$(m active.running_apps "${(j:, :)RUNNING_APPS}")"
}

# ----------------------------------------------------------------------------
# 2. Spotlight — contre-vérification
# ----------------------------------------------------------------------------
SPOT_SUSPECT=0
typeset -ga SPOT_FINDINGS

audit_spotlight() {
  h1 "$(m spot.title)"

  h2 "$(m spot.mdutil.title)"
  typeset -a VOLS; VOLS=("/")
  while IFS= read -r v; do VOLS+=("$v"); done < <(mount | grep -E '^/dev/.* on /Volumes/' | grep -v nobrowse | sed -E 's#^/dev/[^ ]+ on (/Volumes/.*) \(.*$#\1#')
  for v in "${VOLS[@]}"; do
    st=$(mdutil -s "$v" 2>&1 | tail -1 | sed 's/^[[:space:]]*//')
    # Les motifs ci-dessous lisent la sortie (anglaise) de mdutil : ce ne sont pas des messages.
    case "$st" in
      *"Indexing enabled"*) ok "$(m spot.mdutil.enabled "$v" "$st")" ;;
      *"disabled"*)         warn "$(m spot.mdutil.disabled "$v" "$st")" ;;
      *"could not resolve"*) warn "$(m spot.mdutil.unreachable "$v" "$st")" ;;
      *) bad "$(m spot.mdutil.abnormal "$v" "$st")"; SPOT_FINDINGS+=("$(m spot.finding.mdutil "$v" "$st")"); (( SPOT_SUSPECT++ )) ;;
    esac
  done

  h2 "$(m spot.size.title)"
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
    info "$(m spot.size.system "$(human $SPOT_IDX_KB)" "$(printf '%.2f' $ratio)")"
    if (( ratio > 8 )); then
      bad "$(m spot.size.bloated)"
      SPOT_FINDINGS+=("$(m spot.finding.ratio "$(printf '%.1f' $ratio)")"); (( SPOT_SUSPECT++ ))
    fi
  else
    warn "$(m spot.size.no_sudo)"
  fi
  info "$(m spot.size.user "$(human $USER_IDX_KB)")"

  h2 "$(m spot.sample.title)"
  SAMPLE_DIR=""
  for cand in "$HOME/Documents" "$HOME/Desktop" "$HOME/Pictures" "$HOME/Movies" "$HOME/Music" "$HOME"; do
    [[ -d "$cand" ]] && ls "$cand" >/dev/null 2>&1 && [[ -n "$(find "$cand" -maxdepth 3 -type f -not -path '*/.*' -print -quit 2>/dev/null)" ]] && { SAMPLE_DIR="$cand"; break; }
  done
  [[ -z "$SAMPLE_DIR" ]] && SAMPLE_DIR="$HOME"
  info "$(m spot.sample.dir "${SAMPLE_DIR/#$HOME/~}")"
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
      (( miss++ )); (( miss <= 5 )) && info "  $(m spot.sample.missing "${f/#$HOME/~}")"
    fi
  done < "$TMP/sample"
  if (( ! TCC_OK )); then
    warn "$(m spot.sample.inconclusive "$miss" "$n")"
  elif (( n == 0 )); then
    warn "$(m spot.sample.empty "$SAMPLE_DIR")"
  else
    pct=$(( miss * 100 / n ))
    if (( pct > 20 )); then
      bad "$(m spot.sample.bad "$miss" "$n" "$pct")"
      SPOT_FINDINGS+=("$(m spot.finding.sample "$miss" "$n")"); (( SPOT_SUSPECT++ ))
    elif (( pct > 5 )); then
      warn "$(m spot.sample.warn "$miss" "$n" "$pct")"
    else
      ok "$(m spot.sample.ok "$miss" "$n" "$pct")"
    fi
  fi

  h2 "$(m spot.probe.title)"
  PROBE="$HOME/mister-clean-probe-$RUN_ID.txt"
  print -- "mister-clean probe $RUN_ID" > "$PROBE" 2>/dev/null
  found=0
  for i in {1..15}; do
    sleep 1
    if mdfind -name "mister-clean-probe-$RUN_ID" 2>/dev/null | grep -q .; then found=$i; break; fi
  done
  rm -f "$PROBE"
  if (( found )); then ok "$(m spot.probe.ok "$found")"
  elif (( ! TCC_OK )); then warn "$(m spot.probe.inconclusive)"
  else bad "$(m spot.probe.bad)"
       SPOT_FINDINGS+=("$(m spot.finding.probe)"); (( SPOT_SUSPECT++ )); fi

  h2 "$(m spot.log.title)"
  if (( FAST )); then
    info "$(m spot.log.skipped)"
  else
    run_with_timeout 120 log show --last 2h --style compact \
        --predicate 'process == "mds" OR process == "mds_stores" OR process BEGINSWITH "mdworker"' 2>/dev/null \
      | grep -iE 'corrupt|damaged|invalid index|rebuilding index|reset index|index.*unusable' > "$TMP/mdslog" || true
    errs=$(wc -l < "$TMP/mdslog" | tr -d ' ')
    if (( errs > 0 )); then
      bad "$(m spot.log.bad "$errs")"
      head -3 "$TMP/mdslog" | cut -c1-200 | sed 's/^/      /'
      SPOT_FINDINGS+=("$(m spot.finding.log "$errs")"); (( SPOT_SUSPECT++ ))
    else ok "$(m spot.log.ok)"; fi
  fi
  mdcpu=$(ps -Ao %cpu,comm | awk '$2 ~ /mds_stores|mdworker|mds$/ {s+=$1} END {printf "%.0f", s+0}')
  if (( mdcpu > 150 )); then warn "$(m spot.cpu.high "$mdcpu")"
  else info "$(m spot.cpu.info "$mdcpu")"; fi

  h2 "$(m spot.verdict.title)"
  if (( SPOT_SUSPECT == 0 && ! TCC_OK )); then
    warn "$(m spot.verdict.inconclusive)"
  elif (( SPOT_SUSPECT == 0 )); then
    ok "$(m spot.verdict.healthy)"
  else
    bad "$(m spot.verdict.suspect "$SPOT_SUSPECT")"
    for f in "${SPOT_FINDINGS[@]}"; do info "  – $f"; done
    add_candidate spotlight "$(m spotlight.rebuild.label)" "$SPOT_IDX" "$SPOT_IDX_KB" "-" \
      caution "$(m spotlight.rebuild.reason)" \
      "sudo:mdutil -E /"
  fi
}

# ----------------------------------------------------------------------------
# 3. Caches
# ----------------------------------------------------------------------------
scan_cache_dir() {  # scan_cache_dir CATEGORIE RACINE  (chaque sous-dossier devient un candidat)
  local cat="$1" root="$2" d kb age v reason forced
  [[ -d "$root" ]] || return 0
  for d in "$root"/*(N); do
    [[ "${d:t}" == "Homebrew" || "${d:t}" == "pip" ]] && continue   # gérés par leur outil (brew cleanup, pip cache purge)
    kb=$(du_kb "$d"); (( kb < 10240 )) && continue   # < 10 MiB : pas la peine
    age=$(newest_age_days "$d")
    forced=""
    case "${d:t}" in
      com.apple.*) forced="$(m caches.apple.reason)" ;;
      CloudKit*|com.apple.bird*) forced="$(m caches.icloud.reason)" ;;
    esac
    IFS='|' read -r v reason <<< "$(verdict_for "$d" "$CACHE_DAYS" "$forced")"
    add_candidate "$cat" "${d:t}" "$d" "$kb" "$age" "$v" "$reason" "rm-contents:$d"
  done
}

audit_caches() {
  h1 "$(m caches.title)"

  info "~/Library/Caches…";   scan_cache_dir cache_app "$HOME/Library/Caches"
  info "~/.cache…";           scan_cache_dir cache_cli "$HOME/.cache"

  # Journaux
  for logroot in "$HOME/Library/Logs" "/Library/Logs/DiagnosticReports" "$HOME/Library/Logs/DiagnosticReports"; do
    [[ -d "$logroot" ]] || continue
    kb=$(find "$logroot" -type f -mtime +"$CACHE_DAYS" -print0 2>/dev/null | xargs -0 du -sk 2>/dev/null | awk '{s+=$1} END {print s+0}')
    (( kb < 5120 )) && continue
    add_candidate logs "$(m logs.label "${logroot/#$HOME/~}" "$CACHE_DAYS")" "$logroot" "$kb" "$CACHE_DAYS+" \
      safe "$(m logs.reason)" "rm-old-files:$logroot:$CACHE_DAYS"
  done

  # Outils développeur
  h2 "$(m dev.title)"
  XC="$HOME/Library/Developer/Xcode"
  if [[ -d "$XC/DerivedData" ]]; then
    kb=$(du_kb "$XC/DerivedData"); forced=""; is_running Xcode && forced="$(m xcode.open.reason)"
    IFS='|' read -r v reason <<< "$(verdict_for "$XC/DerivedData" "$CACHE_DAYS" "$forced")"
    (( kb > 0 )) && add_candidate xcode "$(m xcode.derived.label)" "$XC/DerivedData" "$kb" "$(newest_age_days "$XC/DerivedData")" "$v" "$reason" "rm-contents:$XC/DerivedData"
  fi
  for ds in "$XC"/*DeviceSupport(N); do
    kb=$(du_kb "$ds"); (( kb > 0 )) && add_candidate xcode "$(m xcode.devicesupport.label "${ds:t}")" "$ds" "$kb" "$(newest_age_days "$ds")" \
      safe "$(m xcode.devicesupport.reason)" "rm-contents:$ds"
  done
  [[ -d "$XC/Archives" ]] && { kb=$(du_kb "$XC/Archives"); (( kb > 0 )) && add_candidate xcode "$(m xcode.archives.label)" "$XC/Archives" "$kb" "$(newest_age_days "$XC/Archives")" \
      manual "$(m xcode.archives.reason)" "none"; }
  CS="$HOME/Library/Developer/CoreSimulator"
  if [[ -d "$CS/Caches" ]]; then
    kb=$(du_kb "$CS/Caches")
    IFS='|' read -r v reason <<< "$(verdict_for "$CS/Caches" "$CACHE_DAYS")"
    (( kb > 0 )) && add_candidate simulator "CoreSimulator/Caches" "$CS/Caches" "$kb" "$(newest_age_days "$CS/Caches")" "$v" "$reason" "rm-contents:$CS/Caches"
  fi
  if [[ -d "$CS/Devices" ]] && have xcrun; then
    kb=$(du_kb "$CS/Devices")
    (( kb > 0 )) && add_candidate simulator "$(m sim.unavailable.label)" "$CS/Devices" "$kb" "-" \
      safe "$(m sim.unavailable.reason)" "cmd:xcrun simctl delete unavailable"
  fi

  # Gestionnaires de paquets
  h2 "$(m pkg.title)"
  if have brew; then
    bc=$(brew --cache 2>/dev/null); kb=$(du_kb "$bc")
    (( kb > 0 )) && add_candidate homebrew "$(m homebrew.label)" "$bc" "$kb" "$(newest_age_days "$bc")" \
      safe "$(m homebrew.reason)" "cmd:brew cleanup --prune=all -s"
  fi
  [[ -d "$HOME/.npm/_cacache" ]] && { kb=$(du_kb "$HOME/.npm/_cacache"); (( kb > 0 )) && add_candidate npm "$(m npm.label)" "$HOME/.npm/_cacache" "$kb" "$(newest_age_days "$HOME/.npm/_cacache")" \
      safe "$(m reason.redownloaded)" "cmd:npm cache clean --force"; }
  if have pnpm; then
    ps_=$(pnpm store path 2>/dev/null); [[ -d "$ps_" ]] && { kb=$(du_kb "$ps_"); (( kb > 0 )) && add_candidate pnpm "$(m pnpm.label)" "$ps_" "$kb" "$(newest_age_days "$ps_")" \
      safe "$(m pnpm.reason)" "cmd:pnpm store prune"; }
  fi
  if have yarn; then
    yc=$(yarn cache dir 2>/dev/null); [[ -d "$yc" ]] && { kb=$(du_kb "$yc"); (( kb > 10240 )) && add_candidate yarn "$(m yarn.label)" "$yc" "$kb" "$(newest_age_days "$yc")" \
      safe "$(m reason.redownloaded)" "cmd:yarn cache clean"; }
  fi
  have pip3 && { pc=$(pip3 cache dir 2>/dev/null); [[ -d "$pc" && "$pc" != "$HOME/Library/Caches/pip" ]] && { kb=$(du_kb "$pc"); (( kb > 10240 )) && add_candidate pip "$(m pip.label)" "$pc" "$kb" "$(newest_age_days "$pc")" safe "$(m reason.redownloaded)" "cmd:pip3 cache purge"; }; }
  have uv && { uc=$(uv cache dir 2>/dev/null); [[ -d "$uc" ]] && { kb=$(du_kb "$uc"); (( kb > 10240 )) && add_candidate uv "$(m uv.label)" "$uc" "$kb" "$(newest_age_days "$uc")" safe "$(m uv.reason)" "cmd:uv cache prune"; }; }
  [[ -d "$HOME/.cargo/registry" ]] && { kb=$(du_kb "$HOME/.cargo/registry"); (( kb > 10240 )) && add_candidate cargo "$(m cargo.label)" "$HOME/.cargo/registry" "$kb" "$(newest_age_days "$HOME/.cargo/registry")" \
      caution "$(m cargo.reason)" "rm-contents:$HOME/.cargo/registry/cache"; }
  [[ -d "$HOME/go/pkg/mod" ]] && { kb=$(du_kb "$HOME/go/pkg/mod"); (( kb > 10240 )) && add_candidate go "$(m go.label)" "$HOME/go/pkg/mod" "$kb" "$(newest_age_days "$HOME/go/pkg/mod")" \
      caution "$(m go.reason)" "cmd:go clean -modcache"; }
  if [[ -d "$HOME/.gradle/caches" ]]; then
    kb=$(du_kb "$HOME/.gradle/caches")
    IFS='|' read -r v reason <<< "$(verdict_for "$HOME/.gradle/caches" "$CACHE_DAYS")"
    (( kb > 10240 )) && add_candidate gradle "$(m gradle.label)" "$HOME/.gradle/caches" "$kb" "$(newest_age_days "$HOME/.gradle/caches")" "$v" "$reason" "rm-contents:$HOME/.gradle/caches"
  fi

  # Docker
  if have docker && docker info >/dev/null 2>&1; then
    h2 "$(m docker.title)"
    docker system df 2>/dev/null | sed 's/^/    /'
    rec=$(docker system df --format '{{.Reclaimable}}' 2>/dev/null | head -1)
    add_candidate docker "$(m docker.label)" "docker" "0" "-" caution "$(m docker.reason "${rec:-?}")" "cmd:docker system prune -f"
  fi
}

# ----------------------------------------------------------------------------
# 4. Modèles IA anciens
# ----------------------------------------------------------------------------
rel_to_days() {  # "3 weeks ago" -> 21  (sortie anglaise d'ollama list)
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

scan_model_root() {  # scan_model_root CATEGORIE RACINE  (le libellé de catégorie sert de titre)
  local cat="$1" root="$2" d kb age
  [[ -d "$root" ]] || return 0
  h2 "$(m cat.$cat)"
  for d in "$root"/*(N/); do
    kb=$(du_kb "$d"); (( kb < 51200 )) && continue   # < 50 MiB
    age=$(newest_age_days "$d")
    if (( age >= MODEL_DAYS )); then v=caution; reason="$(m model.old.reason "$age" "$MODEL_DAYS")"
    else v=manual; reason="$(m model.recent.reason "$age")"; fi
    add_candidate "$cat" "${d:t}" "$d" "$kb" "$age" "$v" "$reason" "rm-path:$d"
  done
}

audit_models() {
  h1 "$(m models.title)"

  if have ollama; then
    h2 "$(m ollama.title)"
    LOADED=$(ollama ps 2>/dev/null | awk 'NR>1 {print $1}' | tr '\n' ' ')
    OLL_KB=$(du_kb "$HOME/.ollama/models")
    info "$(m ollama.store "$(human $OLL_KB)" "${LOADED:-$(m ollama.none_loaded)}")"
    info "$(m ollama.age_note)"
    ollama list 2>/dev/null | awk 'NR>1' | while read -r name id sz unit n u rest; do
      [[ -z "$name" ]] && continue
      case "$unit" in GB) kb=$(( sz * 1048576 )) ;; MB) kb=$(( sz * 1024 )) ;; *) kb=0 ;; esac
      kb=${kb%.*}
      if [[ "$n" == "About" || "$n" == "an" || "$n" == "a" ]]; then days=0; else days=$(rel_to_days "$n" "$u"); fi
      if [[ " $LOADED " == *" $name "* ]]; then
        v=caution; reason="$(m model.loaded.reason)"
      elif (( days >= MODEL_DAYS )); then
        v=caution; reason="$(m model.ollama_old.reason "$days" "$MODEL_DAYS" "$name")"
      else
        v=manual; reason="$(m model.recent.reason "$days")"
      fi
      add_candidate model_ollama "$name" "ollama:$name" "$kb" "$days" "$v" "$reason" "cmd:ollama rm $name"
    done
  fi

  scan_model_root model_huggingface "$HOME/.cache/huggingface/hub"
  scan_model_root model_lmstudio    "$HOME/.lmstudio/models"
  scan_model_root model_lmstudio    "$HOME/.cache/lm-studio/models"
  scan_model_root model_whisper     "$HOME/.cache/whisper"
  scan_model_root model_torch       "$HOME/.cache/torch/hub/checkpoints"
}

# ----------------------------------------------------------------------------
# 5. Gros volumes divers
# ----------------------------------------------------------------------------
audit_big() {
  h1 "$(m big.title)"

  # Snapshots Time Machine locaux
  if (( SNAP_COUNT > 0 )); then
    tmutil listlocalsnapshots / 2>/dev/null | grep 'com.apple.TimeMachine' | while read -r s; do
      d="${s#com.apple.TimeMachine.}"; d="${d%.local}"
      add_candidate tm_snapshot "$d" "snapshot:$d" "0" "-" caution "$(m snapshot.reason)" "cmd:tmutil deletelocalsnapshots $d"
    done
  fi

  # Corbeille
  kb=$(du_kb "$HOME/.Trash")
  (( kb > 10240 )) && add_candidate trash "~/.Trash" "$HOME/.Trash" "$kb" "$(newest_age_days "$HOME/.Trash")" caution "$(m trash.reason)" "rm-contents:$HOME/.Trash"

  # Sauvegardes iOS, pièces jointes Mail
  MB="$HOME/Library/Application Support/MobileSync/Backup"
  [[ -d "$MB" ]] && { kb=$(du_kb "$MB"); (( kb > 10240 )) && add_candidate ios_backups "MobileSync/Backup" "$MB" "$kb" "$(newest_age_days "$MB")" manual "$(m ios_backups.reason)" "none"; }
  MD="$HOME/Library/Containers/com.apple.mail/Data/Library/Mail Downloads"
  [[ -d "$MD" ]] && { kb=$(du_kb "$MD"); (( kb > 10240 )) && add_candidate mail "$(m mail.label)" "$MD" "$kb" "$(newest_age_days "$MD")" safe "$(m mail.reason)" "rm-contents:$MD"; }

  # node_modules / .venv / target de projets inactifs
  h2 "$(m deps.title)"
  find "$HOME" -maxdepth 6 \( -name node_modules -o -name .venv -o -name venv -o -name target \) -type d -prune \
    -not -path "$HOME/Library/*" -not -path "$HOME/.*" 2>/dev/null | while read -r d; do
    proj="${d:h}"
    [[ "${d:t}" == "target" && ! -f "$proj/Cargo.toml" ]] && continue
    kb=$(du_kb "$d"); (( kb < 51200 )) && continue
    age=$(newest_age_days "$proj")
    (( age < ACTIVE_DAYS )) && continue
    add_candidate inactive_project "${proj/#$HOME/~}/${d:t}" "$d" "$kb" "$age" caution "$(m deps.reason "$age")" "rm-path:$d"
  done

  # Téléchargements : gros fichiers anciens (liste seulement)
  h2 "$(m downloads.title)"
  find "$HOME/Downloads" -maxdepth 1 -type f -size +100M -mtime +90 -print0 2>/dev/null \
    | xargs -0 du -sk 2>/dev/null | sort -rn | head -"$TOP" | while read -r kb f; do
      info "$(printf '%9s' "$(human $kb)")  ${f/#$HOME/~}"
    done
  kb=$(find "$HOME/Downloads" -maxdepth 1 -type f -size +100M -mtime +90 -print0 2>/dev/null | xargs -0 du -sk 2>/dev/null | awk '{s+=$1} END{print s+0}')
  (( kb > 0 )) && add_candidate downloads "$(m downloads.label)" "$HOME/Downloads" "$kb" "90+" manual "$(m reason.sort_by_hand)" "none"

  # Données d'applications (informatif : jamais touché, mais souvent là que ça pèse)
  h2 "$(m appdata.title "$TOP")"
  { du -xk -d 1 "$HOME/Library/Application Support" 2>/dev/null; du -xk -d 1 "$HOME/Library/Containers" 2>/dev/null; } \
    | sort -rn | awk -F'\t' -v a="$HOME/Library/Application Support" -v c="$HOME/Library/Containers" '$2!=a && $2!=c' | head -"$TOP" | while IFS=$'\t' read -r kb d; do
      info "$(printf '%9s' "$(human $kb)")  ${d/#$HOME/~}"
    done

  AC="$HOME/Library/Application Support/com.apple.container"
  [[ -d "$AC" ]] && { kb=$(du_kb "$AC"); (( kb > 102400 )) && add_candidate apple_container "$(m apple_container.label)" "$AC" "$kb" "$(newest_age_days "$AC")" manual "$(m apple_container.reason)" "none"; }
  MW="$HOME/Library/Application Support/MacWhisper"
  [[ -d "$MW" ]] && { kb=$(du_kb "$MW"); (( kb > 102400 )) && add_candidate model_macwhisper "$(m macwhisper.label)" "$MW" "$kb" "$(newest_age_days "$MW")" manual "$(m macwhisper.reason)" "none"; }

  # Top dossiers du home (vue d'ensemble)
  if (( ! FAST )); then
    h2 "$(m home.title "$TOP")"
    du -xk -d 2 "$HOME" 2>/dev/null | sort -rn | awk -v home="$HOME" 'NR>1 && NR<=1000 {print}' | head -"$TOP" | while read -r kb d; do
      info "$(printf '%9s' "$(human $kb)")  ${d/#$HOME/~}"
    done
  fi
}

# ----------------------------------------------------------------------------
# 6. Plan de nettoyage
# ----------------------------------------------------------------------------
describe_action() {
  local kind="${1%%:*}" arg="${1#*:}"
  case "$kind" in
    rm-contents)  print -- "$(m action.rm_contents "${arg/#$HOME/~}")" ;;
    rm-path)      print -- "$(m action.rm_path "${arg/#$HOME/~}")" ;;
    rm-old-files) print -- "$(m action.rm_old_files "${arg##*:}" "${${arg%:*}/#$HOME/~}")" ;;
    cmd)          print -- "$arg" ;;
    sudo)         print -- "sudo $arg" ;;
    *)            print -- "$1" ;;
  esac
}

print_group() {  # print_group VERDICT TITRE
  local want="$1" title="$2" i shown=0
  for i in "${ORDER[@]}"; do
    [[ "${CAND_VERDICT[$i]}" == "$want" ]] || continue
    if (( ! shown )); then h2 "$title"; shown=1; fi
    printf "  %-9s  %-16s  %-48s  %s\n" "$(human ${CAND_KB[$i]})" "$(m cat.${CAND_CAT[$i]})" "${CAND_LABEL[$i]:0:48}" "${C_DIM}${CAND_REASON[$i]}${C_RESET}"
    [[ "${CAND_ACTION[$i]}" != "none" ]] && printf "  %-9s  %-16s  ${C_DIM}→ %s${C_RESET}\n" "" "" "$(describe_action "${CAND_ACTION[$i]}")"
  done
  (( shown )) || { h2 "$title"; info "$(m plan.group.empty)"; }
}

show_plan() {
  h1 "$(m plan.title)"

  typeset -ga ORDER; ORDER=()
  # tri par taille décroissante
  for i in {1..${#CAND_PATH}}; do print -- "${CAND_KB[$i]} $i"; done | sort -rn | awk '{print $2}' | while read -r i; do ORDER+=("$i"); done

  SAFE_KB=0 CAUT_KB=0 MAN_KB=0 SAFE_N=0 CAUT_N=0 MAN_N=0
  for i in {1..${#CAND_PATH}}; do
    case "${CAND_VERDICT[$i]}" in
      safe)    (( SAFE_KB += CAND_KB[$i] )); (( SAFE_N++ )) ;;
      caution) (( CAUT_KB += CAND_KB[$i] )); (( CAUT_N++ )) ;;
      manual)  (( MAN_KB  += CAND_KB[$i] )); (( MAN_N++ )) ;;
    esac
  done

  print_group safe    "${C_GREEN}$(m plan.group.safe    "$(m verdict.safe)"    "$SAFE_N" "$(human $SAFE_KB)")${C_RESET}"
  print_group caution "${C_YELLOW}$(m plan.group.caution "$(m verdict.caution)" "$CAUT_N" "$(human $CAUT_KB)")${C_RESET}"
  print_group manual  "${C_DIM}$(m plan.group.manual   "$(m verdict.manual)"  "$MAN_N"  "$(human $MAN_KB)")${C_RESET}"

  print
  say "$(m plan.summary "$(human $SAFE_KB)" "$(human $CAUT_KB)" "$(human $MAN_KB)")"
  say "$(m plan.status "${#ACTIVE_PROJECTS}" "$( ((SPOT_SUSPECT)) && print -- "${C_RED}$(m plan.spotlight.suspect)${C_RESET}" || print -- "${C_GREEN}$(m plan.spotlight.healthy)${C_RESET}" )")"
}

# ----------------------------------------------------------------------------
# 7. Exécution
# ----------------------------------------------------------------------------
run_action() {  # run_action ACTION  -> exécute, 0 si ok
  local a="$1" kind="${1%%:*}" arg="${1#*:}" p days
  case "$kind" in
    rm-contents) p="$arg"; [[ -d "$p" && "$p" == "$HOME"/* ]] || { bad "$(m exec.path_refused "$p")"; return 1; }
                 find "$p" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null ;;
    rm-path)     p="$arg"; [[ -e "$p" && "$p" == "$HOME"/* && "$p" != "$HOME" ]] || { bad "$(m exec.path_refused "$p")"; return 1; }
                 rm -rf "$p" ;;
    rm-old-files) p="${arg%:*}"; days="${arg##*:}"
                 find "$p" -type f -mtime +"$days" -delete 2>/dev/null
                 find "$p" -mindepth 1 -type d -empty -delete 2>/dev/null ;;
    cmd)         eval "$arg" ;;
    sudo)        sudo $=arg ;;
    none)        return 0 ;;
    *)           bad "$(m exec.unknown_action "$a")"; return 1 ;;
  esac
}

ask() {  # ask "question" -> 0 si la réponse figure dans answer.confirm_yes
  local r
  print -n -- "$1 "
  read -r r
  answer_in answer.confirm_yes "$r"
}

execute_plan() {
  h1 "$(m exec.title)"

  FREED_BEFORE=$(df -k "$DATA_VOL" | tail -1 | awk '{print $4}')
  DONE_N=0

  if (( SAFE_N > 0 )); then
    if (( ASSUME_YES )) || ask "$(m exec.confirm_safe "$SAFE_N" "$(human $SAFE_KB)")"; then
      for i in "${ORDER[@]}"; do
        [[ "${CAND_VERDICT[$i]}" == safe && "${CAND_ACTION[$i]}" != "none" ]] || continue
        print -n -- "  ${CAND_LABEL[$i]:0:60} … "
        if run_action "${CAND_ACTION[$i]}" >> "$LOG_FILE" 2>&1; then print -- "${C_GREEN}$(m exec.ok)${C_RESET}"; (( DONE_N++ )); else print -- "${C_RED}$(m exec.failed)${C_RESET}"; fi
      done
    else
      info "$(m exec.safe_skipped)"
    fi
  fi

  if (( CAUT_N > 0 )) && [[ -t 0 ]]; then
    print
    say "$(m exec.caution_intro)"
    for i in "${ORDER[@]}"; do
      [[ "${CAND_VERDICT[$i]}" == caution && "${CAND_ACTION[$i]}" != "none" ]] || continue
      print -n -- "  [$(human ${CAND_KB[$i]})] $(m cat.${CAND_CAT[$i]}) · ${CAND_LABEL[$i]:0:50} — ${C_DIM}${CAND_REASON[$i]}${C_RESET}  $(m exec.caution_choices) "
      read -r r
      if answer_in answer.item_quit "$r"; then
        break
      elif answer_in answer.item_yes "$r"; then
        if run_action "${CAND_ACTION[$i]}" >> "$LOG_FILE" 2>&1; then ok "$(m exec.done)"; (( DONE_N++ )); else bad "$(m exec.failed)"; fi
      else
        info "$(m exec.skipped)"
      fi
    done
  elif (( CAUT_N > 0 )); then
    info "$(m exec.caution_not_offered)"
  fi

  sleep 2
  FREED_AFTER=$(df -k "$DATA_VOL" | tail -1 | awk '{print $4}')
  FREED=$(( FREED_AFTER - FREED_BEFORE )); (( FREED < 0 )) && FREED=0
  print
  say "$(m exec.summary "$DONE_N" "$(human $FREED)" "$(human $FREED_AFTER)")"
  dim "$(m exec.apfs_note)"
  dim "$(m exec.log "$LOG_FILE")"
}

# ----------------------------------------------------------------------------
# Programme principal
# ----------------------------------------------------------------------------
main() {
  parse_args "$@"
  if [[ "$(uname -s)" != "Darwin" ]]; then
    print -u2 -- "$(m err.macos_only)"; exit 1
  fi
  setup_output
  audit_disk
  audit_active
  (( SKIP_SPOTLIGHT )) || audit_spotlight
  audit_caches
  audit_models
  audit_big
  show_plan
  if (( DRY_RUN )); then
    print
    dim "$(m plan.dry_run)"
    return 0
  fi
  execute_plan
}

# Exécuté (./mister-clean.sh, zsh mister-clean.sh) : lance l'audit.
# Chargé (source mister-clean.sh, cas des tests) : définit seulement les
# fonctions et les réglages par défaut, sans rien auditer ni supprimer.
# Le trap est posé ici, hors de toute fonction : en zsh, un trap EXIT posé
# dans une fonction se déclencherait dès la fin de celle-ci.
if [[ "$ZSH_EVAL_CONTEXT" == toplevel ]]; then
  trap '[[ -n "${TMP-}" ]] && rm -rf "$TMP"' EXIT
  main "$@"
fi
