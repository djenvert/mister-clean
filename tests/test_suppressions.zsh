# Garde de chemin unique pour toute suppression (issue #6) : chaque genre
# d'action est réellement exécuté sur le HOME jetable, cas refusés compris.

# _run ACTION_ZSH : charge le script, exécute run_action sur l'action donnée
# (expression zsh évaluée dans le bac à sable) et affiche « rc=… » et le refus.
_run() {
  in_sandbox "$2"'
    run_action "$('"$1"')"; print -r -- "rc=$? refus=$REFUSAL"'
}

# Chemins aux caractères particuliers : espace et deux-points.
_bizarre() { print -r -- "$H/Library/Caches/mon app:v2"; }

test_rm_contents_vide_le_dossier_avec_espace_et_deux_points() {
  local d="$(_bizarre)"
  make_file "$d/a.bin" 4; make_file "$d/sous dossier/b.bin" 4; make_file "$H/Library/Caches/voisin/c" 4
  _run 'new_action rm-contents "$HOME/Library/Caches/mon app:v2"'
  assert_contains "$OUT" "rc=0 refus="
  assert_exists "$d"
  [[ -z "$(ls -A "$d")" ]] || fail "dossier non vidé : $(ls -A "$d")"
  assert_exists "$H/Library/Caches/voisin/c"
}

test_rm_path_supprime_le_chemin_avec_espace_et_deux_points() {
  local d="$(_bizarre)"
  make_file "$d/a.bin" 4; make_file "$H/Library/Caches/mon app/garde" 4
  _run 'new_action rm-path "$HOME/Library/Caches/mon app:v2"'
  assert_contains "$OUT" "rc=0 refus="
  assert_not_exists "$d"
  assert_exists "$H/Library/Caches/mon app/garde"
}

test_rm_old_files_ne_supprime_que_les_vieux_fichiers() {
  local d="$H/Library/Logs/app: x"
  make_file "$d/vieux.log" 4 200; make_file "$d/vide/vieux.log" 4 200; make_file "$d/recent.log" 4 1
  _run 'new_action rm-old-files "$HOME/Library/Logs/app: x" 30'
  assert_contains "$OUT" "rc=0 refus="
  assert_not_exists "$d/vieux.log"; assert_not_exists "$d/vide"
  assert_exists "$d/recent.log"
}

test_rm_old_files_dans_un_emplacement_autorise_hors_de_home() {
  local d="$MC_SANDBOX/journaux-systeme"
  mkdir -p "$d"; print x > "$d/vieux.crash"; age_path "$d/vieux.crash" 200
  _run 'new_action rm-old-files "$MC_SANDBOX/journaux-systeme" 30' \
       'DELETE_ALLOWED_OUTSIDE_HOME=("$MC_SANDBOX/journaux-systeme");'
  assert_contains "$OUT" "rc=0 refus="
  assert_not_exists "$d/vieux.crash"
}

test_chaque_genre_refuse_hors_de_home() {
  local d="$MC_SANDBOX/dehors" k
  for k in rm-contents rm-path rm-old-files; do
    mkdir -p "$d"; print x > "$d/f"; age_path "$d" 200
    _run "new_action $k \"\$MC_SANDBOX/dehors\" 30"
    assert_contains "$OUT" "rc=2 refus=chemin refusé : $d (hors de ~ et des emplacements autorisés)"
    assert_exists "$d/f"
  done
}

test_refus_home_lui_meme_vide_relatif_non_canonique() {
  make_file "$H/precieux" 4 200
  local -A cas
  cas=(
    '$HOME'                       'racine ou dossier personnel'
    '$HOME/'                      'chemin non canonique'
    '$HOME/Library/..'            'chemin non canonique'
    '$HOME/Library/../..'         'chemin non canonique'
    '$HOME//Library'              'chemin non canonique'
    'Library/Caches'              'chemin relatif'
    ''                            'chemin vide'
  )
  local c k
  for c in "${(@k)cas}"; do
    for k in rm-contents rm-path rm-old-files; do
      _run "new_action $k \"$c\" 30"
      assert_contains "$OUT" "rc=2 refus=chemin refusé : "
      assert_contains "$OUT" "(${cas[$c]})"
      assert_exists "$H/precieux"
    done
  done
}

test_refus_de_la_racine_sans_rien_lancer() {
  # find et rm sont remplacés par des leurres : même si la garde laissait
  # passer « / », rien ne serait effacé.
  local k
  for k in rm-contents rm-path rm-old-files; do
    _run "new_action $k / 30" 'find() { print LEURRE find; }; rm() { print LEURRE rm; };'
    assert_contains "$OUT" "rc=2 refus=chemin refusé : / (racine ou dossier personnel)"
    assert_not_contains "$OUT" "LEURRE"
  done
}

test_refus_des_liens_symboliques_vers_l_exterieur() {
  local dehors="$MC_SANDBOX/dehors"
  mkdir -p "$dehors/sous" "$H/Library/Caches"; print x > "$dehors/sous/f"
  ln -s "$dehors" "$H/Library/Caches/lien"
  _run 'new_action rm-contents "$HOME/Library/Caches/lien"'
  assert_contains "$OUT" "(lien symbolique)"
  _run 'new_action rm-path "$HOME/Library/Caches/lien/sous"'
  assert_contains "$OUT" "(hors de ~ et des emplacements autorisés)"
  assert_exists "$dehors/sous/f"
}

test_rm_old_files_refuse_un_nombre_de_jours_invalide() {
  make_file "$H/Library/Logs/x/vieux.log" 4 200
  _run 'new_action rm-old-files "$HOME/Library/Logs/x" "30; rm -rf ~"'
  assert_contains "$OUT" "rc=2 refus=action inconnue"
  assert_exists "$H/Library/Logs/x/vieux.log"
}

test_plan_et_execution_partagent_la_definition() {
  in_sandbox '
    a="$(new_action rm-old-files "$HOME/Library/Logs/a:b c" 30)"
    describe_action "$a"
    describe_action "$(new_action rm-contents "$HOME/x y")"
    describe_action "$(new_action rm-path "$HOME/z")"'
  assert_status 0
  [[ "$OUT" == $'supprimer les fichiers > 30 j dans ~/Library/Logs/a:b c\nvider ~/x y/\nsupprimer ~/z' ]] \
    || fail "descriptions : $OUT"
}

test_execution_affiche_le_refus() {
  local d="$MC_SANDBOX/dehors"; mkdir -p "$d"; print x > "$d/f"
  in_sandbox '
    LOG_FILE="$MC_SANDBOX/journal"; DATA_VOL=/; ASSUME_YES=1
    add_candidate cache_app dehors "$MC_SANDBOX/dehors" 1 1 safe r "$(new_action rm-contents "$MC_SANDBOX/dehors")"
    write_plan "$MC_SANDBOX/plan"; execute_plan "$MC_SANDBOX/plan"'
  assert_contains "$OUT" "chemin refusé : $d (hors de ~ et des emplacements autorisés)"
  assert_contains "$OUT" "0 action(s) exécutée(s)"
  assert_exists "$d/f"
}

test_execution_reelle_de_bout_en_bout() {
  local c="$H/Library/Caches/com.example.ancien"
  make_file "$c/blob.bin" 12288; age_path "$c" 200
  # Rapports de plantage « système » : le bac à sable remplace le vrai dossier.
  local sys="$MC_SANDBOX/system-logs"
  mkdir -p "$sys"; dd if=/dev/urandom of="$sys/vieux.crash" bs=1024 count=12000 2>/dev/null
  age_path "$sys" 200
  run_script --yes --skip-spotlight --lang fr
  assert_status 0
  assert_contains "$OUT" "com.example.ancien … ok"
  assert_exists "$c"
  assert_not_exists "$c/blob.bin"
  assert_contains "$OUT" "→ supprimer les fichiers > 30 j dans $sys"
  assert_not_exists "$sys/vieux.crash"
  assert_not_called sudo
}
