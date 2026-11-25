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
    git.reason.clean        "worktree propre et poussé, non modifié depuis ≥ %s j"
    git.reason.dirty        "modifications non commitées : à commiter ou jeter à la main"
    git.reason.unpushed     "%s commit(s) non poussé(s)"
    git.reason.no_upstream  "pas de branche distante : travail jamais poussé"
    git.reason.detached     "HEAD détaché : commits peut-être sur aucune branche"
    git.reason.not_worktree "pas un worktree git (ou dépôt parent introuvable)"
    git.reason.recent       "worktree modifié il y a moins de %s j"

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
    cargo.label             "registry Rust (crates téléchargées)"
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
    plan.bad_line           "plan, ligne %s ignorée (mal formée) : %s"
    plan.unreadable         "plan illisible : %s"

    # --- 7. Exécution
    exec.title              "7. Exécution"
    exec.path_refused       "chemin refusé : %s (%s)"
    guard.empty             "chemin vide"
    guard.relative          "chemin relatif"
    guard.not_canonical     "chemin non canonique"
    guard.symlink           "lien symbolique"
    guard.root_or_home      "racine ou dossier personnel"
    guard.outside           "hors de ~ et des emplacements autorisés"
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
    git.reason.clean        "clean, pushed worktree, untouched for ≥ %s d"
    git.reason.dirty        "uncommitted changes: commit or discard them by hand"
    git.reason.unpushed     "%s unpushed commit(s)"
    git.reason.no_upstream  "no remote branch: work never pushed"
    git.reason.detached     "detached HEAD: commits may be on no branch"
    git.reason.not_worktree "not a git worktree (or parent repository missing)"
    git.reason.recent       "worktree modified less than %s d ago"

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
    cargo.label             "Rust registry (downloaded crates)"
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
    plan.bad_line           "plan, line %s ignored (malformed): %s"
    plan.unreadable         "unreadable plan: %s"

    # --- 7. Execution
    exec.title              "7. Execution"
    exec.path_refused       "path refused: %s (%s)"
    guard.empty             "empty path"
    guard.relative          "relative path"
    guard.not_canonical     "non-canonical path"
    guard.symlink           "symbolic link"
    guard.root_or_home      "root or home folder"
    guard.outside           "outside ~ and the allowed locations"
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
# Actions de nettoyage
# ----------------------------------------------------------------------------
# Une action est une liste de mots, rangée dans CAND_ACTION sous forme d'une
# seule chaîne (chaque mot protégé par ${(q)…}) : espaces, deux-points et
# autres caractères particuliers des chemins passent tels quels.
#
#   none                        rien à exécuter (candidat MANUEL)
#   rm-contents CHEMIN          vider le dossier CHEMIN
#   rm-path CHEMIN              supprimer CHEMIN
#   rm-old-files CHEMIN JOURS   supprimer les fichiers de plus de JOURS j sous CHEMIN
#   cmd OUTIL [ARGS…]           lancer un outil (brew, ollama, tmutil…)
#   sudo OUTIL [ARGS…]          le même, avec droits élevés (via sudo)
#
# Les commandes ne sont jamais évaluées par le shell : OUTIL et chaque ARG
# sont passés tels quels, même s'ils contiennent $( ), ;, *, espaces…
#
# new_action construit une action ; describe_action (plan) et run_action
# (exécution) passent tous deux par action_do, où chaque genre définit côte à
# côte sa description et son exécution. Toute suppression de fichiers passe
# d'abord par deletion_guard.

# Rapports de plantage système, seul dossier hors de ~ que le script nettoie.
# MISTER_CLEAN_SYSTEM_LOGS le remplace (la suite de tests y met un dossier du
# bac à sable, pour ne jamais toucher aux vrais journaux).
SYSTEM_LOGS_DIR="${MISTER_CLEAN_SYSTEM_LOGS:-/Library/Logs/DiagnosticReports}"

# Seuls emplacements hors de ~ où le script peut supprimer des fichiers
# (eux-mêmes ou ce qu'ils contiennent). Tout autre chemin hors de ~ est refusé.
typeset -ga DELETE_ALLOWED_OUTSIDE_HOME
DELETE_ALLOWED_OUTSIDE_HOME=("$SYSTEM_LOGS_DIR")

# Raison du dernier refus de deletion_guard (texte déjà rendu).
REFUSAL=""

# new_action GENRE [ARGS…] : affiche l'action encodée.
new_action() { print -r -- "${(j: :)${(q)@}}"; }

# deletion_guard CHEMIN : 0 si le script peut supprimer CHEMIN ou ce qu'il
# contient. Sinon 1, avec la raison dans REFUSAL (et sur la sortie d'erreur).
# Refusés : chemin vide, relatif ou non canonique (., .., //, / final), lien
# symbolique, racine, ~ lui-même, et tout chemin qui, liens résolus, n'est ni
# sous ~ ni dans DELETE_ALLOWED_OUTSIDE_HOME.
deletion_guard() {
  local p="$1" why="" home="${HOME:A}" real root
  REFUSAL=""
  if [[ -z "$p" ]]; then why=guard.empty
  elif [[ "$p" != /* ]]; then why=guard.relative
  elif [[ "$p" != "${p:a}" ]]; then why=guard.not_canonical
  elif [[ -L "$p" ]]; then why=guard.symlink
  else
    real="${p:A}"
    if [[ "$real" == / || "$real" == "$home" || "$home" == / ]]; then why=guard.root_or_home
    elif [[ "$real" != "$home"/* ]]; then
      why=guard.outside
      for root in "${DELETE_ALLOWED_OUTSIDE_HOME[@]}"; do
        [[ "$real" == "${root:A}" || "$real" == "${root:A}"/* ]] && { why=""; break; }
      done
    fi
  fi
  [[ -z "$why" ]] && return 0
  REFUSAL="$(m exec.path_refused "${p:-\"\"}" "$(m $why)")"
  print -u2 -r -- "$REFUSAL"
  return 1
}

# action_do describe|run ACTION
#   describe : affiche la description de l'action (plan).
#   run      : l'exécute. 0 si réussie, 2 si refusée par la garde (raison dans
#              REFUSAL), autre code en cas d'échec.
action_do() {
  local mode="$1" a="$2"
  local -a w; w=("${(@Q)${(z)a}}")
  local kind="${w[1]-}" p="${w[2]-}" days="${w[3]-}"
  local -a tool; tool=("${(@)w[2,-1]}")
  case "$kind" in
    none)
      return 0 ;;
    rm-contents)
      [[ "$mode" == describe ]] && { print -r -- "$(m action.rm_contents "${p/#$HOME/~}")"; return 0; }
      deletion_guard "$p" || return 2
      [[ -d "$p" ]] || return 0
      find "$p" -mindepth 1 -maxdepth 1 -exec rm -rf {} + ;;
    rm-path)
      [[ "$mode" == describe ]] && { print -r -- "$(m action.rm_path "${p/#$HOME/~}")"; return 0; }
      deletion_guard "$p" || return 2
      [[ -e "$p" ]] || return 0
      rm -rf -- "$p" ;;
    rm-old-files)
      [[ "$mode" == describe ]] && { print -r -- "$(m action.rm_old_files "$days" "${p/#$HOME/~}")"; return 0; }
      deletion_guard "$p" || return 2
      [[ "$days" == <-> ]] || { REFUSAL="$(m exec.unknown_action "$a")"; print -u2 -r -- "$REFUSAL"; return 2; }
      [[ -d "$p" ]] || return 0
      find "$p" -type f -mtime +"$days" -delete
      find "$p" -mindepth 1 -type d -empty -delete ;;
    cmd|sudo)
      # Description : la commande telle qu'on la taperait (mots protégés si besoin).
      if [[ "$mode" == describe ]]; then
        [[ "$kind" == sudo ]] && tool=(sudo "${tool[@]}")
        print -r -- "${(j: :)${(@q-)tool}}"; return 0
      fi
      (( ${#tool} )) || { REFUSAL="$(m exec.unknown_action "$a")"; print -u2 -r -- "$REFUSAL"; return 2; }
      # Une seule voie pour les deux : sudo n'est qu'un préfixe de la liste.
      [[ "$kind" == sudo ]] && tool=(sudo -- "${tool[@]}")
      "${tool[@]}" ;;
    *)
      [[ "$mode" == describe ]] && { print -r -- "$a"; return 0; }
      REFUSAL="$(m exec.unknown_action "$a")"; print -u2 -r -- "$REFUSAL"
      return 2 ;;
  esac
}

describe_action() { action_do describe "$1"; }   # describe_action ACTION
run_action()      { action_do run "$1"; }        # run_action ACTION

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
      "$(new_action sudo mdutil -E /)"
  fi
}

# ----------------------------------------------------------------------------
# Sondes enregistrées
# ----------------------------------------------------------------------------
# Une section (logs, dev, pkg, models, big, appdata…) rassemble les lignes du
# catalogue SOURCES qui portent son nom et les sondes sur mesure inscrites ici.
# Une sonde sur mesure sert quand l'emplacement ne suffit pas à décrire la
# source : l'outil liste lui-même ses objets (ollama list, docker system df,
# tmutil), ou il faut une recherche (dépendances de projets inactifs).
#
# PROBES : entrées « section:fonction », lancées dans cet ordre par
# run_section. La fonction réservée « catalogue » désigne les lignes SOURCES
# de la section ; si une section n'en mentionne pas, elles passent en premier.
# L'ordre compte : c'est celui des candidats dans le plan.
#
# Contrat d'une sonde (fonction probe_<nom>, sans argument) :
#   - elle ne propose ses candidats que par add_candidate ou add_model
#     (le filet de sécurité s'applique ainsi à elle aussi) ;
#   - ses actions sont construites par new_action (voir Actions de nettoyage) ;
#   - elle ne supprime rien, ne lance aucune commande qui modifie le disque ;
#   - elle n'affiche que par h2 / info (et des listes indentées informatives) ;
#   - si l'outil dont elle dépend est absent, elle ne fait rien et rend 0 ;
#   - ses variables sont locales.
typeset -ga PROBES
PROBES=(
  caches:probe_app_caches
  caches:probe_cli_caches
  pkg:catalogue
  pkg:probe_docker
  models:probe_ollama
  models:catalogue
  big:probe_snapshots
  big:catalogue
  big:probe_inactive_deps
  big:probe_downloads
)

# run_section SECTION : lance les lignes du catalogue et les sondes de SECTION.
run_section() {
  local sec="$1" e
  local -a mine
  for e in "${PROBES[@]}"; do [[ "${e%%:*}" == "$sec" ]] && mine+=("${e#*:}"); done
  (( ${mine[(Ie)catalogue]} )) || mine=(catalogue "${mine[@]}")
  for e in "${mine[@]}"; do
    if [[ "$e" == catalogue ]]; then probe_sources "$sec"; else "$e"; fi
  done
}

# ----------------------------------------------------------------------------
# 3. Caches
# ----------------------------------------------------------------------------
# ----------------------------------------------------------------------------
# Catalogue des sources à emplacement connu
# ----------------------------------------------------------------------------
# Seuils de taille, en KiB. Un candidat entre dans le plan si sa taille est
# AU MOINS égale au seuil de sa source.
#   cache    10 Mio  : tout ce qui est régénérable (caches, journaux, corbeille,
#                      sauvegardes…) ; en dessous, le gain ne vaut pas une ligne.
#   bulky    50 Mio  : modèles IA et dépendances de projets, proposés un par un.
#   appdata 100 Mio  : données d'applications (MANUEL, pour information) :
#                      seules les très grosses méritent d'être signalées.
typeset -gA SIZE_MIN
SIZE_MIN=(cache 10240 bulky 51200 appdata 102400)

# Une ligne par source, colonnes séparées par « | » :
#   section  : où la source est sondée (logs, dev, pkg, models, big, appdata)
#   cat      : catégorie (libellé : MSG[cat.<cat>])
#   lieu     : ~/chemin (joker * permis), {syslogs} (SYSTEM_LOGS_DIR),
#              ou « $ commande » : l'emplacement est donné par l'outil
#   outil    : outil requis (sinon la source est ignorée), - si aucun
#   seuil    : clé de SIZE_MIN
#   verdict  : safe | caution | manual, ou une règle de verdict (ci-dessous)
#   raison   : clé du catalogue de messages, - pour un verdict age
#   action   : mots de l'action (voir Actions de nettoyage), ou none
#   libellé  : @clé [args…] (message du catalogue) ou texte littéral
#   taille   : du (taille du dossier) ou nom d'une fonction TAILLE CHEMIN
# Jetons remplacés dans action et libellé : {path} chemin, {tpath} chemin
# abrégé en ~, {name} dernier élément du chemin, {days} valeur de --days.
#
# Règles de verdict (colonne verdict), appliquées par source_verdict :
#   age      safe si rien n'a bougé depuis --days jours, caution sinon ;
#            « age!App=clé » : caution avec la raison MSG[clé] si l'application
#            App tourne.
#   model    règle unique des modèles IA (add_model, selon --model-days) ;
#            la raison est la clé du message « ancien », qui reçoit l'âge et
#            --model-days. Avec un joker (racine/*), chaque modèle est un
#            candidat ; scan_cache_dir ignore ces racines (is_model_area).
#   git      worktrees git (ceux des agents de code) : caution seulement pour
#            un worktree propre, poussé, non modifié depuis --days jours ;
#            manual sinon, avec la raison précise (voir git_verdict). Jamais
#            safe. Outil requis : git. Action conseillée :
#            cmd git -C {path} worktree remove {path}  (sans --force : git
#            refuse lui-même s'il reste du travail).
# Ajouter une règle : une branche dans source_verdict, documentée ici.
#
# Ajouter un outil = ajouter une ligne.
SOURCES='
logs    | logs        | ~/Library/Logs                          | -     | cache   | safe     | logs.reason                | rm-old-files {path} {days}         | @logs.label {tpath} {days}   | old_files_kb
logs    | logs        | {syslogs}                               | -     | cache   | safe     | logs.reason                | rm-old-files {path} {days}         | @logs.label {tpath} {days}   | old_files_kb
logs    | logs        | ~/Library/Logs/DiagnosticReports        | -     | cache   | safe     | logs.reason                | rm-old-files {path} {days}         | @logs.label {tpath} {days}   | old_files_kb
dev     | xcode       | ~/Library/Developer/Xcode/DerivedData   | -     | cache   | age!Xcode=xcode.open.reason | -     | rm-contents {path}                 | @xcode.derived.label         | du
dev     | xcode       | ~/Library/Developer/Xcode/*DeviceSupport | -    | cache   | safe     | xcode.devicesupport.reason | rm-contents {path}                 | @xcode.devicesupport.label {name} | du
dev     | xcode       | ~/Library/Developer/Xcode/Archives      | -     | cache   | manual   | xcode.archives.reason      | none                               | @xcode.archives.label        | du
dev     | simulator   | ~/Library/Developer/CoreSimulator/Caches | -    | cache   | age      | -                          | rm-contents {path}                 | CoreSimulator/Caches         | du
dev     | simulator   | ~/Library/Developer/CoreSimulator/Devices | xcrun | cache | safe     | sim.unavailable.reason     | cmd xcrun simctl delete unavailable | @sim.unavailable.label      | sim_unavailable_kb
pkg     | homebrew    | $ brew --cache                          | brew  | cache   | safe     | homebrew.reason            | cmd brew cleanup --prune=all -s    | @homebrew.label              | du
pkg     | npm         | ~/.npm/_cacache                         | -     | cache   | safe     | reason.redownloaded        | cmd npm cache clean --force        | @npm.label                   | du
pkg     | pnpm        | $ pnpm store path                       | pnpm  | cache   | safe     | pnpm.reason                | cmd pnpm store prune               | @pnpm.label                  | du
pkg     | yarn        | $ yarn cache dir                        | yarn  | cache   | safe     | reason.redownloaded        | cmd yarn cache clean               | @yarn.label                  | du
pkg     | pip         | $ pip3 cache dir                        | pip3  | cache   | safe     | reason.redownloaded        | cmd pip3 cache purge               | @pip.label                   | du
pkg     | uv          | $ uv cache dir                          | uv    | cache   | safe     | uv.reason                  | cmd uv cache prune                 | @uv.label                    | du
pkg     | cargo       | ~/.cargo/registry/cache                 | -     | cache   | caution  | cargo.reason               | rm-contents {path}                 | @cargo.label                 | du
pkg     | go          | ~/go/pkg/mod                            | -     | cache   | caution  | go.reason                  | cmd go clean -modcache             | @go.label                    | du
pkg     | gradle      | ~/.gradle/caches                        | -     | cache   | age      | -                          | rm-contents {path}                 | @gradle.label                | du
big     | trash       | ~/.Trash                                | -     | cache   | caution  | trash.reason               | rm-contents {path}                 | ~/.Trash                     | du
big     | ios_backups | ~/Library/Application Support/MobileSync/Backup | - | cache | manual   | ios_backups.reason         | none                               | MobileSync/Backup            | du
big     | mail        | ~/Library/Containers/com.apple.mail/Data/Library/Mail Downloads | - | cache | safe | mail.reason   | rm-contents {path}                 | @mail.label                  | du
models  | model_huggingface | ~/.cache/huggingface/hub/*          | -     | bulky   | model    | model.old.reason           | rm-path {path}                     | {name}                       | du
models  | model_lmstudio   | ~/.lmstudio/models/*                   | -     | bulky   | model    | model.old.reason           | rm-path {path}                     | {name}                       | du
models  | model_lmstudio   | ~/.cache/lm-studio/models/*            | -     | bulky   | model    | model.old.reason           | rm-path {path}                     | {name}                       | du
models  | model_whisper    | ~/.cache/whisper/*                     | -     | bulky   | model    | model.old.reason           | rm-path {path}                     | {name}                       | du
models  | model_torch      | ~/.cache/torch/hub/checkpoints/*       | -     | bulky   | model    | model.old.reason           | rm-path {path}                     | {name}                       | du
appdata | apple_container  | ~/Library/Application Support/com.apple.container | - | appdata | manual | apple_container.reason | none                     | @apple_container.label       | du
appdata | model_macwhisper | ~/Library/Application Support/MacWhisper | -    | appdata | manual | macwhisper.reason        | none                               | @macwhisper.label            | du
'

# Tailles particulières (colonne taille) : TAILLE CHEMIN -> KiB.
# old_files_kb : fichiers plus vieux que --days seulement (ce que rm-old-files retire).
old_files_kb() {
  find "$1" -type f -mtime +"$CACHE_DAYS" -print0 2>/dev/null | xargs -0 du -sk 2>/dev/null | awk '{s+=$1} END {print s+0}'
}
# sim_unavailable_kb : seuls les simulateurs que « delete unavailable » retire.
sim_unavailable_kb() {
  local u kb=0
  for u in ${(f)"$(xcrun simctl list devices unavailable 2>/dev/null | grep -oE '[0-9A-F]{8}(-[0-9A-F]{4}){3}-[0-9A-F]{12}' | sort -u)"}; do
    (( kb += $(du_kb "$1/$u") ))
  done
  print -- $kb
}

# _source_fill MODÈLE CHEMIN : remplace les jetons {path} {tpath} {name} {days}.
_source_fill() {
  local t="$1" p="$2"
  t="${t//\{path\}/$p}"; t="${t//\{tpath\}/${p/#$HOME/~}}"
  t="${t//\{name\}/${p:t}}"; t="${t//\{days\}/$CACHE_DAYS}"
  print -r -- "$t"
}

# probe_sources SECTION : sonde chaque source du catalogue de cette section et
# propose ses candidats au registre (add_candidate applique le filet).
probe_sources() {
  setopt local_options extended_glob
  local want="$1" line sec cat loc tool min verdict reason action label size
  local p kb w label_txt
  local -a f places words largs
  for line in ${(f)SOURCES}; do
    [[ "$line" == [[:space:]]#(\#*|) ]] && continue
    f=("${(@s:|:)line}"); f=("${(@)${(@)f##[[:space:]]##}%%[[:space:]]##}")
    sec="$f[1]" cat="$f[2]" loc="$f[3]" tool="$f[4]" min="$f[5]" verdict="$f[6]"
    reason="$f[7]" action="$f[8]" label="$f[9]" size="$f[10]"
    [[ "$sec" == "$want" ]] || continue
    [[ "$tool" == - ]] || have "$tool" || continue
    # Emplacement(s)
    case "$loc" in
      '$ '*)     places=("$(${(z)${loc#\$ }} 2>/dev/null)") ;;
      '{syslogs}') places=("$SYSTEM_LOGS_DIR") ;;
      *)         loc="${loc/#\~/$HOME}"
                 if [[ "$loc" == *'*'* ]]; then places=(${~loc}(N/)); else places=("$loc"); fi ;;
    esac
    for p in "${places[@]}"; do
      [[ -n "$p" && -d "$p" ]] || continue
      if [[ "$size" == du ]]; then kb=$(du_kb "$p"); else kb=$($size "$p"); fi
      (( kb >= SIZE_MIN[$min] )) || continue
      # Action et libellé
      words=()
      for w in ${(z)action}; do words+=("$(_source_fill "$w" "$p")"); done
      if [[ "$label" == @* ]]; then
        largs=(); for w in ${(z)label#@}; do largs+=("$(_source_fill "$w" "$p")"); done
        label_txt="$(m "${largs[@]}")"
      else
        label_txt="$(_source_fill "$label" "$p")"
      fi
      source_verdict "$verdict" "$reason" "$cat" "$label_txt" "$p" "$kb" "$(new_action "${words[@]}")"
    done
  done
}

# source_verdict VERDICT RAISON CAT LIBELLÉ CHEMIN KB ACTION : applique la
# colonne verdict d'une source (valeur fixe ou règle de verdict) et propose le
# candidat au registre. Les titres de catégorie des modèles s'affichent ici,
# une fois par catégorie.
typeset -g _LAST_MODEL_CAT=""
source_verdict() {
  local verdict="$1" reason="$2" cat="$3" label="$4" p="$5" kb="$6" action="$7"
  local v r app key age
  age="$(newest_age_days "$p")"
  case "$verdict" in
    age*)
      r=""
      if [[ "$verdict" == age!* ]]; then
        app="${${verdict#age!}%%=*}"; key="${verdict#*=}"
        is_running "$app" && r="$(m $key)"
      fi
      IFS='|' read -r v r <<< "$(verdict_for "$p" "$CACHE_DAYS" "$r")"
      add_candidate "$cat" "$label" "$p" "$kb" "$age" "$v" "$r" "$action" ;;
    git)
      IFS='|' read -r v r <<< "$(git_verdict "$p" "$CACHE_DAYS")"
      add_candidate "$cat" "$label" "$p" "$kb" "$age" "$v" "$r" "$action" ;;
    model)
      [[ "$_LAST_MODEL_CAT" == "$cat" ]] || { h2 "$(m cat.$cat)"; _LAST_MODEL_CAT="$cat"; }
      add_model "$cat" "$label" "$p" "$kb" "$age" 0 "$(m $reason "$age" "$MODEL_DAYS")" "$action" ;;
    *)
      add_candidate "$cat" "$label" "$p" "$kb" "$age" "$verdict" "$(m $reason)" "$action" ;;
  esac
}

scan_cache_dir() {  # scan_cache_dir CATEGORIE RACINE  (chaque sous-dossier devient un candidat)
  local cat="$1" root="$2" d kb age v reason forced
  [[ -d "$root" ]] || return 0
  for d in "$root"/*(N); do
    [[ "${d:t}" == "Homebrew" || "${d:t}" == "pip" ]] && continue   # sources du catalogue (brew cleanup, pip cache purge)
    is_model_area "$d" && continue   # modèles IA : règle des modèles (section 4)
    kb=$(du_kb "$d"); (( kb >= SIZE_MIN[cache] )) || continue
    age=$(newest_age_days "$d")
    forced=""
    case "${d:t}" in
      com.apple.*) forced="$(m caches.apple.reason)" ;;
      CloudKit*|com.apple.bird*) forced="$(m caches.icloud.reason)" ;;
    esac
    IFS='|' read -r v reason <<< "$(verdict_for "$d" "$CACHE_DAYS" "$forced")"
    add_candidate "$cat" "${d:t}" "$d" "$kb" "$age" "$v" "$reason" "$(new_action rm-contents "$d")"
  done
}

probe_app_caches() { info "~/Library/Caches…"; scan_cache_dir cache_app "$HOME/Library/Caches"; }
probe_cli_caches() { info "~/.cache…"; scan_cache_dir cache_cli "$HOME/.cache"; }

# Docker : pas d'emplacement à mesurer, l'outil annonce lui-même ce qu'il récupère.
probe_docker() {
  have docker && docker info >/dev/null 2>&1 || return 0
  local rec
  h2 "$(m docker.title)"
  docker system df 2>/dev/null | sed 's/^/    /'
  rec=$(docker system df --format '{{.Reclaimable}}' 2>/dev/null | head -1)
  add_candidate docker "$(m docker.label)" "docker" "0" "-" caution "$(m docker.reason "${rec:-?}")" "$(new_action cmd docker system prune -f)"
}

audit_caches() {
  h1 "$(m caches.title)"
  run_section caches
  run_section logs
  h2 "$(m dev.title)"
  run_section dev
  h2 "$(m pkg.title)"
  run_section pkg
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

# add_model CAT LABEL CHEMIN KB ÂGE CHARGÉ RAISON_SI_ANCIEN ACTION
# Règle unique pour tous les modèles IA locaux, quelle que soit la source :
#   chargé en mémoire (CHARGÉ=1)  → caution (« actuellement chargé »)
#   ÂGE ≥ --model-days            → caution, RAISON_SI_ANCIEN (propre à la
#                                   source : comment récupérer le modèle)
#   sinon                         → manual : récent, conservé
# Un modèle n'est donc jamais safe. Le registre (add_candidate) rétrograde en
# caution un modèle en conflit (projet en cours, fichier ouvert).
add_model() {
  local cat="$1" label="$2" p="$3" kb="$4" age="$5" loaded="$6" old_reason="$7" action="$8" v reason
  if (( loaded )); then v=caution; reason="$(m model.loaded.reason)"
  elif (( age >= MODEL_DAYS )); then v=caution; reason="$old_reason"
  else v=manual; reason="$(m model.recent.reason "$age")"; fi
  add_candidate "$cat" "$label" "$p" "$kb" "$age" "$v" "$reason" "$action"
}

# git_verdict CHEMIN JOURS -> "VERDICT|raison" pour un worktree git.
# Tout ce qui pourrait contenir du travail irrécupérable reste manual :
# pas un worktree lié (.git doit être un fichier), modifications non
# commitées (fichiers non suivis compris), HEAD détaché, pas de branche
# distante, commits non poussés, modifié depuis moins de JOURS jours.
# Sinon caution, jamais safe.
git_verdict() {
  local p="$1" days="$2" top n
  local -a g; g=(git -C "$p")
  if [[ ! -f "$p/.git" ]] || ! top="$($g rev-parse --show-toplevel 2>/dev/null)" || [[ "${top:A}" != "${p:A}" ]]; then
    print -r -- "manual|$(m git.reason.not_worktree)"; return
  fi
  [[ -z "$($g status --porcelain 2>/dev/null)" ]] || { print -r -- "manual|$(m git.reason.dirty)"; return; }
  $g symbolic-ref -q HEAD >/dev/null 2>&1 || { print -r -- "manual|$(m git.reason.detached)"; return; }
  $g rev-parse --verify -q '@{upstream}' >/dev/null 2>&1 || { print -r -- "manual|$(m git.reason.no_upstream)"; return; }
  n="$($g rev-list --count '@{upstream}..HEAD' 2>/dev/null)"
  [[ "$n" == <-> ]] || { print -r -- "manual|$(m git.reason.no_upstream)"; return; }
  (( n == 0 )) || { print -r -- "manual|$(m git.reason.unpushed "$n")"; return; }
  is_recent "$p" "$days" && { print -r -- "manual|$(m git.reason.recent "$days")"; return; }
  print -r -- "caution|$(m git.reason.clean "$days")"
}

# model_roots : racines de modèles déclarées au catalogue (lignes au verdict
# model), chemins absolus, joker final retiré. Le scan des caches (~/.cache)
# les ignore : elles relèvent de la règle des modèles, pas de celle des caches.
model_roots() {
  setopt local_options extended_glob
  local line loc
  local -a f
  for line in ${(f)SOURCES}; do
    [[ "$line" == [[:space:]]#(\#*|) ]] && continue
    f=("${(@s:|:)line}"); f=("${(@)${(@)f##[[:space:]]##}%%[[:space:]]##}")
    [[ "$f[6]" == model ]] || continue
    loc="${f[3]/#\~/$HOME}"
    print -r -- "${loc%/\*}"
  done
}

# is_model_area CHEMIN : vrai si CHEMIN est une racine de modèles ou en contient une.
is_model_area() {
  local root
  for root in ${(f)"$(model_roots)"}; do
    [[ "$root" == "$1" || "$root" == "$1"/* ]] && return 0
  done
  return 1
}

# Ollama : l'outil liste lui-même ses modèles, leur âge et ceux qui sont chargés.
probe_ollama() {
  local LOADED OLL_KB name id sz unit n u rest kb days loaded
  have ollama || return 0
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
    loaded=0; [[ " $LOADED " == *" $name "* ]] && loaded=1
    add_model model_ollama "$name" "ollama:$name" "$kb" "$days" "$loaded" \
      "$(m model.ollama_old.reason "$days" "$MODEL_DAYS" "$name")" "$(new_action cmd ollama rm "$name")"
  done
}

audit_models() {
  h1 "$(m models.title)"
  run_section models
}

# ----------------------------------------------------------------------------
# 5. Gros volumes divers
# ----------------------------------------------------------------------------
# Snapshots Time Machine locaux (comptés par audit_disk).
probe_snapshots() {
  (( SNAP_COUNT > 0 )) || return 0
  local s d
  tmutil listlocalsnapshots / 2>/dev/null | grep 'com.apple.TimeMachine' | while read -r s; do
    d="${s#com.apple.TimeMachine.}"; d="${d%.local}"
    add_candidate tm_snapshot "$d" "snapshot:$d" "0" "-" caution "$(m snapshot.reason)" "$(new_action cmd tmutil deletelocalsnapshots "$d")"
  done
}

# node_modules / .venv / target de projets inactifs
probe_inactive_deps() {
  local d proj kb age
  h2 "$(m deps.title)"
  find "$HOME" -maxdepth 6 \( -name node_modules -o -name .venv -o -name venv -o -name target \) -type d -prune \
    -not -path "$HOME/Library/*" -not -path "$HOME/.*" 2>/dev/null | while read -r d; do
    proj="${d:h}"
    [[ "${d:t}" == "target" && ! -f "$proj/Cargo.toml" ]] && continue
    kb=$(du_kb "$d"); (( kb >= SIZE_MIN[bulky] )) || continue
    age=$(newest_age_days "$proj")
    (( age < ACTIVE_DAYS )) && continue
    add_candidate inactive_project "${proj/#$HOME/~}/${d:t}" "$d" "$kb" "$age" caution "$(m deps.reason "$age")" "$(new_action rm-path "$d")"
  done
}

# Téléchargements : gros fichiers anciens (liste, puis un seul candidat MANUEL)
probe_downloads() {
  local kb f
  h2 "$(m downloads.title)"
  find "$HOME/Downloads" -maxdepth 1 -type f -size +100M -mtime +90 -print0 2>/dev/null \
    | xargs -0 du -sk 2>/dev/null | sort -rn | head -"$TOP" | while read -r kb f; do
      info "$(printf '%9s' "$(human $kb)")  ${f/#$HOME/~}"
    done
  kb=$(find "$HOME/Downloads" -maxdepth 1 -type f -size +100M -mtime +90 -print0 2>/dev/null | xargs -0 du -sk 2>/dev/null | awk '{s+=$1} END{print s+0}')
  (( kb > 0 )) && add_candidate downloads "$(m downloads.label)" "$HOME/Downloads" "$kb" "90+" manual "$(m reason.sort_by_hand)" "none"
  return 0
}

audit_big() {
  local kb d
  h1 "$(m big.title)"

  run_section big

  # Données d'applications (informatif : jamais touché, mais souvent là que ça pèse)
  h2 "$(m appdata.title "$TOP")"
  { du -xk -d 1 "$HOME/Library/Application Support" 2>/dev/null; du -xk -d 1 "$HOME/Library/Containers" 2>/dev/null; } \
    | sort -rn | awk -F'\t' -v a="$HOME/Library/Application Support" -v c="$HOME/Library/Containers" '$2!=a && $2!=c' | head -"$TOP" | while IFS=$'\t' read -r kb d; do
      info "$(printf '%9s' "$(human $kb)")  ${d/#$HOME/~}"
    done

  run_section appdata

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
# L'audit produit un plan sous forme de fichier texte ; l'affichage et
# l'exécution ne lisent que ce fichier (load_plan). Format, version 1 :
#
#   - une ligne par candidat, dans l'ordre d'affichage et d'exécution, faite
#     de mots protégés comme en shell (guillemets, apostrophes, \) :
#       VERDICT CATÉGORIE KIB ÂGE LIBELLÉ RAISON CHEMIN ACTION…
#     VERDICT : safe | caution | manual ; CATÉGORIE : clé cat.<…> du catalogue
#     de messages ; KIB : taille en KiB ; ÂGE : jours, ou - ; ACTION… : les
#     mots de l'action (voir Actions de nettoyage), « none » si aucune ;
#   - « meta active_projects N » et « meta spotlight healthy|suspect » : état
#     affiché sous le plan ;
#   - lignes vides et lignes commençant par # ignorées.
#
# Exemple :
#   meta active_projects 0
#   meta spotlight healthy
#   safe cache_app 12288 200 com.example 'non modifié depuis ≥ 30 j' /Users/moi/Library/Caches/com.example rm-contents /Users/moi/Library/Caches/com.example
#   manual xcode 512000 40 Archives 'à trier à la main' /Users/moi/Library/Developer/Xcode/Archives none
#
# Le plan de chaque exécution est conservé à côté de son journal
# (~/Library/Logs/mister-clean/run-….plan).

# write_plan FICHIER : écrit le plan issu du registre des candidats, trié par
# taille décroissante.
write_plan() {
  local f="$1" i
  local -a order fields
  order=(${(f)"$(for (( i = 1; i <= ${#CAND_PATH}; i++ )); do print -- "${CAND_KB[$i]} $i"; done | sort -rn | awk '{print $2}')"})
  {
    print -r -- "# mister-clean $VERSION — plan de nettoyage (format 1, décrit dans le script, section 6)"
    print -r -- "meta active_projects ${#ACTIVE_PROJECTS}"
    print -r -- "meta spotlight $( (( SPOT_SUSPECT )) && print suspect || print healthy )"
    for i in "${order[@]}"; do
      fields=("$CAND_VERDICT[i]" "$CAND_CAT[i]" "$CAND_KB[i]" "$CAND_AGE[i]" "$CAND_LABEL[i]" "$CAND_REASON[i]" "$CAND_PATH[i]")
      print -r -- "${(j: :)${(@q)fields}} $CAND_ACTION[i]"   # CAND_ACTION : déjà des mots protégés
    done
  } > "$f"
}

# Plan chargé par load_plan (mêmes colonnes que le registre des candidats).
typeset -ga PLAN_VERDICT PLAN_CAT PLAN_KB PLAN_AGE PLAN_LABEL PLAN_REASON PLAN_PATH PLAN_ACTION
typeset -gA PLAN_META

# load_plan FICHIER : charge le plan. Une ligne mal formée est signalée et
# ignorée ; un fichier illisible fait échouer (code 1).
load_plan() {
  setopt local_options extended_glob
  local f="$1" line n=0
  local -a w
  PLAN_VERDICT=() PLAN_CAT=() PLAN_KB=() PLAN_AGE=() PLAN_LABEL=() PLAN_REASON=() PLAN_PATH=() PLAN_ACTION=()
  PLAN_META=()
  [[ -r "$f" ]] || { print -u2 -r -- "$(m plan.unreadable "$f")"; return 1; }
  while IFS= read -r line || [[ -n "$line" ]]; do
    (( n++ ))
    [[ "$line" == [[:space:]]#(\#*|) ]] && continue
    w=("${(@Q)${(z)line}}")
    case "${w[1]}" in
      meta)
        PLAN_META[${w[2]-}]="${w[3]-}" ;;
      safe|caution|manual)
        if (( ${#w} >= 8 )) && [[ "${w[3]}" == <-> ]]; then
          PLAN_VERDICT+=("$w[1]"); PLAN_CAT+=("$w[2]"); PLAN_KB+=("$w[3]"); PLAN_AGE+=("$w[4]")
          PLAN_LABEL+=("$w[5]"); PLAN_REASON+=("$w[6]"); PLAN_PATH+=("$w[7]")
          PLAN_ACTION+=("$(new_action "${(@)w[8,-1]}")")
        else
          warn "$(m plan.bad_line "$n" "$line")"
        fi ;;
      *)
        warn "$(m plan.bad_line "$n" "$line")" ;;
    esac
  done < "$f"
}

# plan_totals : nombre d'éléments et taille par verdict du plan chargé.
plan_totals() {
  local i
  SAFE_KB=0 CAUT_KB=0 MAN_KB=0 SAFE_N=0 CAUT_N=0 MAN_N=0
  for (( i = 1; i <= ${#PLAN_VERDICT}; i++ )); do
    case "${PLAN_VERDICT[$i]}" in
      safe)    (( SAFE_KB += PLAN_KB[$i] )); (( SAFE_N++ )) ;;
      caution) (( CAUT_KB += PLAN_KB[$i] )); (( CAUT_N++ )) ;;
      manual)  (( MAN_KB  += PLAN_KB[$i] )); (( MAN_N++ )) ;;
    esac
  done
}

print_group() {  # print_group VERDICT TITRE  (plan chargé)
  local want="$1" title="$2" i shown=0
  for (( i = 1; i <= ${#PLAN_VERDICT}; i++ )); do
    [[ "${PLAN_VERDICT[$i]}" == "$want" ]] || continue
    if (( ! shown )); then h2 "$title"; shown=1; fi
    printf "  %-9s  %-16s  %-48s  %s\n" "$(human ${PLAN_KB[$i]})" "$(m cat.${PLAN_CAT[$i]})" "${PLAN_LABEL[$i]:0:48}" "${C_DIM}${PLAN_REASON[$i]}${C_RESET}"
    [[ "${PLAN_ACTION[$i]}" != "none" ]] && printf "  %-9s  %-16s  ${C_DIM}→ %s${C_RESET}\n" "" "" "$(describe_action "${PLAN_ACTION[$i]}")"
  done
  (( shown )) || { h2 "$title"; info "$(m plan.group.empty)"; }
}

# show_plan FICHIER : affiche le plan. Ne dépend que du fichier.
show_plan() {
  load_plan "$1" || return 1
  plan_totals
  h1 "$(m plan.title)"

  print_group safe    "${C_GREEN}$(m plan.group.safe    "$(m verdict.safe)"    "$SAFE_N" "$(human $SAFE_KB)")${C_RESET}"
  print_group caution "${C_YELLOW}$(m plan.group.caution "$(m verdict.caution)" "$CAUT_N" "$(human $CAUT_KB)")${C_RESET}"
  print_group manual  "${C_DIM}$(m plan.group.manual   "$(m verdict.manual)"  "$MAN_N"  "$(human $MAN_KB)")${C_RESET}"

  print
  say "$(m plan.summary "$(human $SAFE_KB)" "$(human $CAUT_KB)" "$(human $MAN_KB)")"
  say "$(m plan.status "${PLAN_META[active_projects]:-0}" "$( [[ "${PLAN_META[spotlight]-}" == suspect ]] && print -- "${C_RED}$(m plan.spotlight.suspect)${C_RESET}" || print -- "${C_GREEN}$(m plan.spotlight.healthy)${C_RESET}" )")"
}

# ----------------------------------------------------------------------------
# 7. Exécution
# ----------------------------------------------------------------------------
ask() {  # ask "question" -> 0 si la réponse figure dans answer.confirm_yes
  local r
  print -n -- "$1 "
  read -r r
  answer_in answer.confirm_yes "$r"
}

# Les actions PRUDENCE ne sont proposées, une par une, que sur un terminal.
is_interactive() { [[ -t 0 ]]; }

# execute_plan FICHIER : exécute le plan. Ne dépend que du fichier et des
# réponses de l'utilisateur. --yes ne vaut que pour les actions SÛRES : une
# action PRUDENCE n'est jamais exécutée sans un « oui » pour elle seule.
execute_plan() {
  local i r
  load_plan "$1" || return 1
  plan_totals
  h1 "$(m exec.title)"

  FREED_BEFORE=$(df -k "$DATA_VOL" | tail -1 | awk '{print $4}')
  DONE_N=0

  if (( SAFE_N > 0 )); then
    if (( ASSUME_YES )) || ask "$(m exec.confirm_safe "$SAFE_N" "$(human $SAFE_KB)")"; then
      for (( i = 1; i <= ${#PLAN_VERDICT}; i++ )); do
        [[ "${PLAN_VERDICT[$i]}" == safe && "${PLAN_ACTION[$i]}" != "none" ]] || continue
        print -n -- "  ${PLAN_LABEL[$i]:0:60} … "
        run_action "${PLAN_ACTION[$i]}" >> "$LOG_FILE" 2>&1
        case $? in
          0) print -- "${C_GREEN}$(m exec.ok)${C_RESET}"; (( DONE_N++ )) ;;
          2) print -r -- "${C_RED}${REFUSAL}${C_RESET}" ;;
          *) print -- "${C_RED}$(m exec.failed)${C_RESET}" ;;
        esac
      done
    else
      info "$(m exec.safe_skipped)"
    fi
  fi

  if (( CAUT_N > 0 )) && is_interactive; then
    print
    say "$(m exec.caution_intro)"
    for (( i = 1; i <= ${#PLAN_VERDICT}; i++ )); do
      [[ "${PLAN_VERDICT[$i]}" == caution && "${PLAN_ACTION[$i]}" != "none" ]] || continue
      print -n -- "  [$(human ${PLAN_KB[$i]})] $(m cat.${PLAN_CAT[$i]}) · ${PLAN_LABEL[$i]:0:50} — ${C_DIM}${PLAN_REASON[$i]}${C_RESET}  $(m exec.caution_choices) "
      read -r r
      if answer_in answer.item_quit "$r"; then
        break
      elif answer_in answer.item_yes "$r"; then
        run_action "${PLAN_ACTION[$i]}" >> "$LOG_FILE" 2>&1
        case $? in
          0) ok "$(m exec.done)"; (( DONE_N++ )) ;;
          2) bad "$REFUSAL" ;;
          *) bad "$(m exec.failed)" ;;
        esac
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
  # L'audit s'arrête au plan ; affichage et exécution ne lisent que lui.
  PLAN_FILE="${LOG_FILE%.log}.plan"
  write_plan "$PLAN_FILE"
  show_plan "$PLAN_FILE" || exit 1
  if (( DRY_RUN )); then
    print
    dim "$(m plan.dry_run)"
    return 0
  fi
  execute_plan "$PLAN_FILE"
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
