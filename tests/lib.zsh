# Bibliothèque du harnais de test, chargée par run.zsh avant chaque fichier de test.
#
# Chaque test tourne dans son propre processus zsh, avec un bac à sable neuf :
#   $MC_SANDBOX/home      répertoire personnel jetable (le HOME du script testé)
#   $MC_SANDBOX/bin       seul répertoire du PATH : outils système autorisés
#                         (liens vers les vrais) + outils simulés de tests/stubs
#   $MC_SANDBOX/tmp       TMPDIR du script testé
#   $MC_SANDBOX/calls     journal des appels aux outils simulés (« nom args »)
#   $MC_SANDBOX/running   noms d'applications que pgrep dit lancées (une par ligne)
#   $MC_SANDBOX/open_files, cwds   sortie simulée de lsof (un chemin par ligne)
#   $MC_SANDBOX/system-logs  remplace /Library/Logs/DiagnosticReports
#                         (MISTER_CLEAN_SYSTEM_LOGS) : jamais de vrais journaux
#
# Le script testé tourne depuis le HOME jetable (répertoire courant).
#
# Les outils absents du PATH (brew, docker, ollama, xcrun…) sont donc absents
# pour le script : aucun vrai gestionnaire de paquets n'est interrogé.

TESTS_DIR="${${(%):-%x}:A:h}"
SCRIPT="${TESTS_DIR:h}/mister-clean.sh"

# Outils système réels que le script peut utiliser dans le bac à sable.
MC_REAL_TOOLS=(awk cat cut date dd du find grep head ls mkdir mktemp perl rm sed sleep sort
               stat tail tee touch tr uname wc xargs)

# sandbox_new : crée le bac à sable et exporte MC_SANDBOX, H (le HOME jetable).
# Le nettoyage (rm -rf du bac à sable) est à la charge de l'appelant (run.zsh).
sandbox_new() {
  local t p
  MC_SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/mister-clean-test.XXXXXX")" || fail "mktemp a échoué"
  MC_SANDBOX="${MC_SANDBOX:A}"
  H="$MC_SANDBOX/home"
  [[ "${H:A}" != "${HOME:A}" ]] || fail "le HOME de test ne peut pas être le vrai HOME"
  mkdir -p "$H" "$MC_SANDBOX/bin" "$MC_SANDBOX/tmp"
  : > "$MC_SANDBOX/calls"
  for t in $MC_REAL_TOOLS; do
    p="$(command -v "$t")" || fail "outil système introuvable : $t"
    ln -s "$p" "$MC_SANDBOX/bin/$t"
  done
  for p in "$TESTS_DIR"/stubs/*(N) "$TESTS_DIR"/stubs/_record; do ln -sf "$p" "$MC_SANDBOX/bin/${p:t}"; done
  export MC_SANDBOX H
}

# _sandbox_env : préfixe de commande (tableau MC_ENV) donnant un environnement
# minimal, entièrement tourné vers le bac à sable. MC_LANG choisit la locale.
_sandbox_env() {
  MC_ENV=(env -i "HOME=$H" "USER=${USER:-test}" "PATH=$MC_SANDBOX/bin"
          "TMPDIR=$MC_SANDBOX/tmp/" "LANG=${MC_LANG:-fr_FR.UTF-8}"
          "MC_SANDBOX=$MC_SANDBOX" "MC_STUB_CALLS=$MC_SANDBOX/calls"
          "MISTER_CLEAN_SYSTEM_LOGS=$MC_SANDBOX/system-logs")
}

# run_script ARGS… : exécute le script dans le bac à sable.
# Sortie (stdout+stderr) dans $OUT, code de retour dans $STATUS.
run_script() {
  _sandbox_env
  OUT="$(cd "$H" && $MC_ENV /bin/zsh "$SCRIPT" "$@" 2>&1 </dev/null)"
  STATUS=$?
}

# in_sandbox CODE : exécute CODE (zsh) dans le bac à sable, avec le script
# chargé (source) au préalable. Sortie dans $OUT, code dans $STATUS.
in_sandbox() {
  _sandbox_env
  OUT="$(cd "$H" && $MC_ENV /bin/zsh -f -c "source ${(q)SCRIPT}; $1" 2>&1 </dev/null)"
  STATUS=$?
}

# --- Fabrication du HOME jetable ---------------------------------------------

# make_file CHEMIN TAILLE_KIB [ÂGE_JOURS] : crée un fichier de contenu réel
# (compté par du), daté de ÂGE_JOURS jours (0 par défaut), dossiers parents compris.
make_file() {
  local p="$1" kib="$2" age="${3:-0}"
  [[ "$p" == "$H"/* ]] || fail "make_file hors du HOME de test : $p"
  mkdir -p "${p:h}"
  dd if=/dev/urandom of="$p" bs=1024 count="$kib" 2>/dev/null || fail "dd a échoué : $p"
  age_path "$p" "$age"
}

# age_path CHEMIN JOURS : date CHEMIN et tout son contenu de JOURS jours.
age_path() {
  local stamp; stamp="$(date -v-"$2"d +%Y%m%d%H%M)"
  find "$1" -exec touch -t "$stamp" {} +
}

# --- Assertions ---------------------------------------------------------------

fail() { print -u2 -r -- "    ÉCHEC : $*"; exit 1; }

assert_status() { [[ "$STATUS" == "$1" ]] || fail "code de retour $STATUS, attendu $1"$'\n'"$OUT"; }
assert_contains() {
  [[ "$1" == *"$2"* ]] || fail "texte attendu absent : « $2 »"$'\n'"--- dans :"$'\n'"$1"
}
assert_not_contains() {
  [[ "$1" != *"$2"* ]] || fail "texte inattendu présent : « $2 »"$'\n'"--- dans :"$'\n'"$1"
}
assert_exists() { [[ -e "$1" ]] || fail "devrait exister : $1"; }
assert_not_exists() { [[ ! -e "$1" ]] || fail "ne devrait pas exister : $1"; }
assert_not_called() {
  ! grep -q "^$1\( \|\$\)" "$MC_SANDBOX/calls" || fail "$1 a été appelé : $(grep "^$1" "$MC_SANDBOX/calls")"
}

# section TITRE : lignes de $OUT depuis la ligne contenant TITRE jusqu'au
# prochain titre de groupe du plan (ligne commençant par une lettre et un point)
# ou de section (━━━).
section() {
  print -r -- "$OUT" | awk -v t="$1" '
    index($0, t) { on = 1; print; next }
    on && (/^[A-Z]\. / || /━━━/) { exit }
    on { print }'
}
