# Le registre des candidats applique le filet de sécurité (issue #4) : tout
# candidat qui touche un projet en cours ou un fichier ouvert entre en
# PRUDENCE, quel que soit le scan qui l'a proposé ; MANUEL reste MANUEL.

# --- Le registre seul (script chargé, add_candidate appelé directement) -----

# _registre CODE : charge le script, exécute CODE (qui appelle add_candidate)
# puis affiche chaque candidat sous la forme « verdict|raison ».
_registre() {
  in_sandbox "$1"'
    for i in {1..${#CAND_PATH}}; do print -r -- "${CAND_VERDICT[i]}|${CAND_REASON[i]}"; done'
  assert_status 0
}

test_registre_sans_conflit_garde_le_verdict() {
  _registre 'ACTIVE_PROJECTS=("$HOME/proj"); OPEN_FILES=("$HOME/autre/f")
    add_candidate cache_app x "$HOME/Library/Caches/x" 1 1 safe "raison du scan" "rm-contents:$HOME/Library/Caches/x"'
  [[ "$OUT" == "safe|raison du scan" ]] || fail "obtenu : $OUT"
}

test_registre_fichier_ouvert_retrograde_sur() {
  _registre 'OPEN_FILES=("$HOME/Library/Caches/x/sous/f.db")
    add_candidate cache_app x "$HOME/Library/Caches/x" 1 1 safe "raison du scan" none'
  [[ "$OUT" == "caution|fichier ouvert par un processus : sous/f.db" ]] || fail "obtenu : $OUT"
}

test_registre_fichier_ouvert_voisin_ne_compte_pas() {
  _registre 'OPEN_FILES=("$HOME/Library/Caches/x-bis/f")
    add_candidate cache_app x "$HOME/Library/Caches/x" 1 1 safe "raison du scan" none'
  [[ "$OUT" == "safe|raison du scan" ]] || fail "obtenu : $OUT"
}

test_registre_projet_en_cours_retrograde_sur() {
  _registre 'ACTIVE_PROJECTS=("$HOME/proj")
    add_candidate cache_cli c "$HOME/proj/.cache" 1 1 safe "raison du scan" none'
  [[ "$OUT" == "caution|dans le projet en cours $H/proj" ]] || fail "obtenu : $OUT"
}

test_registre_candidat_contenant_un_projet_en_cours() {
  _registre 'ACTIVE_PROJECTS=("$HOME/.Trash/proj")
    add_candidate trash t "$HOME/.Trash" 1 1 caution "raison du scan" none'
  [[ "$OUT" == "caution|contient le projet en cours $H/.Trash/proj" ]] || fail "obtenu : $OUT"
}

test_registre_prudence_prend_la_raison_du_conflit() {
  _registre 'OPEN_FILES=("$HOME/old/node_modules/a.js")
    add_candidate inactive_project n "$HOME/old/node_modules" 1 1 caution "projet inactif" none'
  [[ "$OUT" == "caution|fichier ouvert par un processus : a.js" ]] || fail "obtenu : $OUT"
}

test_registre_manuel_reste_manuel() {
  _registre 'ACTIVE_PROJECTS=("$HOME/Downloads"); OPEN_FILES=("$HOME/Downloads/x.dmg")
    add_candidate downloads d "$HOME/Downloads" 1 1 manual "à trier" none'
  [[ "$OUT" == "manual|à trier" ]] || fail "obtenu : $OUT"
}

test_registre_ignore_ce_qui_n_est_pas_un_chemin() {
  _registre 'ACTIVE_PROJECTS=("$HOME/proj"); OPEN_FILES=("$HOME/proj/f")
    add_candidate docker d docker 0 - safe "r" none
    add_candidate model_ollama m "ollama:llama3" 0 - caution "r2" none'
  [[ "$OUT" == $'safe|r\ncaution|r2' ]] || fail "obtenu : $OUT"
}

# --- De bout en bout : les scans qui contournaient le filet ------------------

# _vieux NOM_DE_DOSSIER : 12 Mio, rien de modifié depuis 200 jours.
_vieux() { make_file "$1/blob.bin" 12288; age_path "$1" 200; }

test_bout_en_bout_fichier_ouvert_dans_des_caches_surs() {
  local npm="$H/.npm/_cacache" mail="$H/Library/Containers/com.apple.mail/Data/Library/Mail Downloads"
  local cache="$H/Library/Caches/com.example.ouvert" libre="$H/Library/Caches/com.example.libre"
  _vieux "$npm"; _vieux "$mail"; _vieux "$cache"; _vieux "$libre"
  print -l -- "$npm/blob.bin" "$mail/blob.bin" "$cache/blob.bin" > "$MC_SANDBOX/open_files"
  run_script --dry-run --skip-spotlight --lang fr
  assert_status 0
  local safe caution
  safe="$(section 'A. SÛR')"; caution="$(section 'B. PRUDENCE')"
  assert_contains "$safe" "com.example.libre"
  assert_not_contains "$safe" "com.example.ouvert"
  assert_not_contains "$safe" "npm"
  assert_not_contains "$safe" "Mail Downloads"
  assert_contains "$caution" "com.example.ouvert"
  assert_contains "$caution" "cache npm (_cacache)"
  assert_contains "$caution" "Mail Downloads"
  [[ "$(print -r -- "$caution" | grep -c 'fichier ouvert par un processus : blob.bin')" == 3 ]] \
    || fail "3 raisons « fichier ouvert » attendues :"$'\n'"$caution"
  assert_contains "$OUT" "3 fichiers ouverts sous ~"
}

test_bout_en_bout_cache_dans_un_projet_en_cours() {
  # Un shell ouvert dans ~/.cache/outil : c'est un projet en cours.
  local outil="$H/.cache/outil"
  _vieux "$outil"
  print -r -- "$outil" > "$MC_SANDBOX/cwds"
  run_script --dry-run --skip-spotlight --lang fr
  assert_status 0
  assert_not_contains "$(section 'A. SÛR')" "outil"
  assert_contains "$(section 'B. PRUDENCE')" "dans le projet en cours $outil"
}

test_bout_en_bout_dependances_inactives_avec_fichier_ouvert() {
  local nm="$H/vieux/node_modules"
  make_file "$H/vieux/package.json" 1; make_file "$nm/gros.bin" 60000; age_path "$H/vieux" 100
  print -r -- "$nm/gros.bin" > "$MC_SANDBOX/open_files"
  run_script --dry-run --skip-spotlight --lang fr
  assert_contains "$(section 'B. PRUDENCE')" "fichier ouvert par un processus : gros.bin"
  assert_not_contains "$OUT" "projet inactif depuis"
}

test_bout_en_bout_manuel_reste_manuel() {
  make_file "$H/Library/Developer/Xcode/Archives/a.xcarchive/x" 100 10
  print -r -- "$H/Library/Developer/Xcode/Archives/a.xcarchive/x" > "$MC_SANDBOX/open_files"
  run_script --dry-run --skip-spotlight --lang fr
  assert_contains "$(section 'C. MANUEL')" "Archives (.xcarchive + dSYM)"
  assert_not_contains "$(section 'B. PRUDENCE')" "Archives"
}

test_bout_en_bout_le_journal_du_script_ne_protege_rien() {
  # lsof voit toujours le journal de l'exécution en cours, ouvert par tee :
  # il ne doit pas faire passer les vieux journaux en PRUDENCE.
  make_file "$H/Library/Logs/vieille-app/app.log" 6000 200
  print -r -- "$H/Library/Logs/mister-clean/run-en-cours.log" > "$MC_SANDBOX/open_files"
  run_script --dry-run --skip-spotlight --lang fr
  assert_contains "$(section 'A. SÛR')" "~/Library/Logs"
  assert_contains "$OUT" "0 fichiers ouverts sous ~"
}
