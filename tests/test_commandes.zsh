# Commandes d'outil exécutées sans eval (issue #7) : une action « cmd » ou
# « sudo » est une liste d'arguments passée telle quelle à l'outil simulé.

# Valeur piégée : substitution de commande, séparateur, joker, espace,
# apostrophe, saut de ligne et argument vide.
_piege=('x$(touch PIEGE);y' 'a b' '*' "l'apo" $'deux\nlignes' '')

test_cmd_transmet_les_arguments_tels_quels() {
  fake_tool ollama
  in_sandbox 'run_action "$(new_action cmd ollama rm '"${(j: :)${(@qq)_piege}}"')"; print -r -- "rc=$?"'
  assert_contains "$OUT" "rc=0"
  [[ "$(argv_of ollama)" == "$(quoted rm "${_piege[@]}")" ]] \
    || fail "arguments reçus :"$'\n'"$(argv_of ollama)"$'\n'"attendus :"$'\n'"$(quoted rm "${_piege[@]}")"
  assert_not_exists "$H/PIEGE"
}

test_sudo_suit_le_meme_chemin() {
  fake_tool sudo
  in_sandbox 'run_action "$(new_action sudo mdutil -E / '"${(qq)_piege[1]}"')"; print -r -- "rc=$?"'
  assert_contains "$OUT" "rc=0"
  [[ "$(argv_of sudo)" == "$(quoted -- mdutil -E / "${_piege[1]}")" ]] || fail "sudo a reçu : $(argv_of sudo)"
  assert_not_exists "$H/PIEGE"
}

test_le_code_de_retour_de_l_outil_remonte() {
  fake_tool brew 'exit 3'
  in_sandbox 'run_action "$(new_action cmd brew cleanup)"; print -r -- "rc=$?"'
  assert_contains "$OUT" "rc=3"
}

test_description_lisible_et_protegee() {
  in_sandbox '
    describe_action "$(new_action cmd brew cleanup --prune=all -s)"
    describe_action "$(new_action sudo mdutil -E /)"
    describe_action "$(new_action cmd ollama rm "a b;c")"'
  [[ "$OUT" == $'brew cleanup --prune=all -s\nsudo mdutil -E /\nollama rm \'a b;c\'' ]] || fail "descriptions : $OUT"
}

test_aucune_action_par_eval() {
  local hits; hits="$(grep -nwE 'eval' "$SCRIPT" | grep -vE '^[0-9]+:[[:space:]]*#')"
  [[ -z "$hits" ]] || fail "eval encore présent : $hits"
}

test_nom_de_modele_lu_sur_la_machine_transmis_tel_quel() {
  # Le nom vient de la sortie d'ollama list : il ne doit jamais être interprété.
  fake_tool ollama '
    case "$1" in
      list) print "NAME ID SIZE MODIFIED"; print -r -- "x\$(touch\${IFS}PIEGE);y abc 4.1 GB 5 months ago" ;;
    esac'
  in_sandbox 'TMP="$MC_SANDBOX/tmp"; audit_models >/dev/null
    print -r -- "plan=$(describe_action "${CAND_ACTION[1]}")"
    run_action "${CAND_ACTION[1]}"; print -r -- "rc=$?"'
  assert_contains "$OUT" "plan=ollama rm 'x\$(touch\${IFS}PIEGE);y'"
  assert_contains "$OUT" "rc=0"
  assert_contains "$(argv_of ollama)" "$(quoted rm 'x$(touch${IFS}PIEGE);y')"
  assert_not_exists "$H/PIEGE"
}

# --- Taille annoncée = ce que l'action supprime --------------------------------

test_cargo_ne_compte_que_le_cache_vide() {
  make_file "$H/.cargo/registry/index/gros" 30720 100
  make_file "$H/.cargo/registry/cache/crates.crate" 15360 100
  run_script --dry-run --skip-spotlight --lang fr
  local ligne; ligne="$(print -r -- "$OUT" | grep -A1 'registry Rust')"
  assert_contains "$ligne" "15 MiB"
  assert_contains "$ligne" "registry Rust (crates téléchargées)"
  assert_contains "$ligne" "→ vider ~/.cargo/registry/cache/"
}

test_simulateurs_ne_compte_que_les_indisponibles() {
  local u1=11111111-2222-3333-4444-555555555555 u2=AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE
  make_file "$H/Library/Developer/CoreSimulator/Devices/$u1/data" 20480
  make_file "$H/Library/Developer/CoreSimulator/Devices/$u2/data" 30720
  fake_tool xcrun '
    [[ "$*" == "simctl list devices unavailable" ]] && {
      print "== Devices =="
      print "-- iOS 15.0 (unavailable, runtime profile not found) --"
      print "    iPhone 8 ('$u1') (Shutdown) (unavailable, runtime profile not found)"
    }'
  run_script --yes --skip-spotlight --lang fr
  assert_status 0
  local ligne; ligne="$(print -r -- "$OUT" | grep -A1 'Simulateurs indisponibles' | head -2)"
  assert_contains "$ligne" "20 MiB"
  assert_contains "$ligne" "→ xcrun simctl delete unavailable"
  assert_contains "$(argv_of xcrun)" "$(quoted simctl delete unavailable)"
}

test_brew_execute_sans_eval_de_bout_en_bout() {
  make_file "$H/Library/Caches/Homebrew-test/bottle.tar.gz" 12288 100
  fake_tool brew '[[ "$1" == --cache ]] && print -r -- "$HOME/Library/Caches/Homebrew-test"'
  run_script --yes --skip-spotlight --lang fr
  assert_status 0
  assert_contains "$OUT" "→ brew cleanup --prune=all -s"
  assert_contains "$(argv_of brew)" "$(quoted cleanup --prune=all -s)"
}
