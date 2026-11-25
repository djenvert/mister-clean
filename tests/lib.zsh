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
MC_REAL_TOOLS=(awk cat cut date dd du find git grep head ls mkdir mktemp perl rm sed sleep sort
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

# --- Outils simulés propres à un test -----------------------------------------

# fake_tool NOM [CORPS] : installe dans le bac à sable un faux outil NOM (il
# remplace un éventuel outil simulé de tests/stubs). Chaque appel ajoute à
# $MC_SANDBOX/argv.NOM une ligne : ses arguments, protégés comme par quoted.
# CORPS (code zsh, builtins seulement) s'exécute ensuite, avec "$@".
fake_tool() {
  local f="$MC_SANDBOX/bin/$1"
  rm -f "$f"
  { print -r -- '#!/bin/zsh -f'
    print -r -- 'print -r -- "${(j: :)${(@qq)@}}" >> "$MC_SANDBOX/argv.'"$1"'"'
    print -r -- "${2-}"
  } > "$f"
  chmod +x "$f"
}

# argv_of NOM : appels reçus par le faux outil NOM (une ligne par appel).
argv_of() { [[ -f "$MC_SANDBOX/argv.$1" ]] && print -r -- "$(<"$MC_SANDBOX/argv.$1")"; }

# quoted ARGS… : forme attendue d'une ligne de argv_of pour ces arguments.
quoted() { print -r -- "${(j: :)${(@qq)@}}"; }

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

# --- Contrôle du catalogue de sources ----------------------------------------

# CATALOGUE_CHECK : code à passer à in_sandbox. Contrôle chaque ligne de
# SOURCES (colonnes, section, seuil, verdict, outil, fonction de taille) et la
# présence de ses clés de messages en français et en anglais. Affiche une ligne
# par problème (avec la clé et la langue), puis « entrées=N ».
CATALOGUE_CHECK='
    setopt extended_glob; n=0
    for line in ${(f)SOURCES}; do
      [[ "$line" == [[:space:]]#(\#*|) ]] && continue
      f=("${(@s:|:)line}"); f=("${(@)${(@)f##[[:space:]]##}%%[[:space:]]##}")
      (( ${#f} == 10 )) || { print "colonnes: $line"; continue; }
      [[ $f[1] == (logs|dev|pkg|agents|models|big|appdata) ]] || print "section: $line"
      [[ -n "${SIZE_MIN[$f[5]]-}" ]] || print "seuil: $line"
      [[ $f[6] == (safe|caution|manual|age|age!*=*|model|git) ]] || print "verdict: $line"
      for lang in fr en; do
        messages_$lang
        [[ -n "${MSG[cat.$f[2]]-}" ]] || print "cat.$f[2] ($lang)"
        [[ $f[7] == - || -n "${MSG[$f[7]]-}" ]] || print "raison $f[7] ($lang)"
        lw=(${(z)${f[9]#@}})
        [[ $f[9] != @* || -n "${MSG[$lw[1]]-}" ]] || print "libellé $f[9] ($lang)"
        [[ $f[6] != age!* || -n "${MSG[${f[6]#*=}]-}" ]] || print "raison ${f[6]#*=} ($lang)"
      done
      [[ $f[10] == du ]] || whence -w "$f[10]" >/dev/null || print "taille: $f[10]"
      [[ $f[4] == - || $f[3] != "\$ "* || $f[3] == "\$ $f[4] "* ]] || print "outil: $line"
      n=$((n+1))
    done
    print "entrées=$n"'

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
