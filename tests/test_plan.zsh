# Plan de nettoyage comme données entre audit et exécution (issue #9).

# _plan_main : plan écrit à la main dans $MC_SANDBOX/plan (chemins du HOME jetable).
_plan_main() {
  make_file "$H/caches/sur un:deux/x" 4; make_file "$H/caches/a-supprimer/x" 4
  make_file "$H/prudence/un/x" 4; make_file "$H/prudence/deux/x" 4; make_file "$H/manuel/x" 4
  cat > "$MC_SANDBOX/plan" <<PLAN
# plan écrit à la main
meta active_projects 2
meta spotlight suspect

safe cache_app 2048 40 'cache « sûr »' 'raison | avec barre' '$H/caches/sur un:deux' rm-contents '$H/caches/sur un:deux'
safe cache_cli 1024 40 a-supprimer 'raison' '$H/caches/a-supprimer' rm-path '$H/caches/a-supprimer'
caution trash 900 - prudence-un 'à confirmer' '$H/prudence/un' rm-path '$H/prudence/un'
caution trash 800 - prudence-deux 'à confirmer' '$H/prudence/deux' rm-path '$H/prudence/deux'
manual downloads 700 90+ manuel 'à trier' '$H/manuel' none
n'importe quoi
safe cache_app pas-un-nombre 1 x y /z none
PLAN
}

test_l_audit_produit_le_plan_sans_rien_supprimer() {
  local c="$H/Library/Caches/com.example.ancien"
  make_file "$c/blob.bin" 12288; age_path "$c" 200
  run_script --dry-run --skip-spotlight --lang fr
  assert_status 0
  local plan=($H/Library/Logs/mister-clean/run-*.plan(N))
  (( ${#plan} == 1 )) || fail "plan attendu à côté du journal, trouvé : ${plan[*]}"
  local txt="$(<$plan[1])"
  assert_contains "$txt" "meta active_projects 0"
  assert_contains "$txt" "meta spotlight healthy"
  in_sandbox "load_plan ${(q)plan[1]}"'; print -r -- "${#PLAN_VERDICT} $PLAN_VERDICT[1] $PLAN_CAT[1] $PLAN_LABEL[1] $PLAN_PATH[1] $(describe_action "$PLAN_ACTION[1]")"'
  [[ "$OUT" == "1 safe cache_app com.example.ancien $c vider ~/Library/Caches/com.example.ancien/" ]] || fail "plan chargé : $OUT"
  assert_exists "$c/blob.bin"
}

test_aller_retour_ecriture_lecture() {
  make_file "$H/a b:c/x" 4
  in_sandbox '
    add_candidate cache_app "lib « \"x\" » '"'"'y" "$HOME/a b:c" 12 3 safe "r | s; \$(t)" "$(new_action rm-contents "$HOME/a b:c")"
    add_candidate model_ollama "m;n" "ollama:m;n" 34 - caution r2 "$(new_action cmd ollama rm "m;n")"
    write_plan "$MC_SANDBOX/p"
    a=("$CAND_LABEL[1]" "$CAND_REASON[1]" "$CAND_PATH[1]" "$CAND_ACTION[1]" "$CAND_ACTION[2]")
    load_plan "$MC_SANDBOX/p"
    b=("$PLAN_LABEL[2]" "$PLAN_REASON[2]" "$PLAN_PATH[2]" "$PLAN_ACTION[2]" "$PLAN_ACTION[1]")
    [[ "${(pj:\0:)a}" == "${(pj:\0:)b}" ]] && print identique || { print -rl -- $a -- $b; }
    print -r -- "$PLAN_VERDICT[1] $PLAN_KB[1] $PLAN_AGE[1]"'
  [[ "$OUT" == $'identique\ncaution 34 -' ]] || fail "aller-retour :"$'\n'"$OUT"
}

test_l_affichage_ne_depend_que_du_plan() {
  _plan_main
  in_sandbox 'show_plan "$MC_SANDBOX/plan"'
  assert_status 0
  assert_contains "$(section 'A. SÛR')" "(2 éléments, ≈ 3 MiB)"
  assert_contains "$(section 'A. SÛR')" "→ vider ~/caches/sur un:deux/"
  assert_contains "$(section 'A. SÛR')" "raison | avec barre"
  assert_contains "$(section 'B. PRUDENCE')" "(2 éléments, ≈ 2 MiB)"
  assert_contains "$(section 'C. MANUEL')" "manuel"
  assert_contains "$OUT" "Projets en cours protégés : 2 · Spotlight : SUSPECT"
  assert_contains "$OUT" "ligne 10 ignorée (mal formée) : n'importe quoi"
  assert_contains "$OUT" "ligne 11 ignorée (mal formée) : safe cache_app pas-un-nombre"
}

test_executer_un_plan_ecrit_a_la_main() {
  _plan_main
  in_sandbox 'LOG_FILE="$MC_SANDBOX/journal"; DATA_VOL=/; ASSUME_YES=1
    execute_plan "$MC_SANDBOX/plan"'
  assert_status 0
  [[ -d "$H/caches/sur un:deux" && -z "$(ls -A "$H/caches/sur un:deux")" ]] || fail "cache sûr non vidé"
  assert_not_exists "$H/caches/a-supprimer"
  assert_exists "$H/prudence/un/x"; assert_exists "$H/prudence/deux/x"; assert_exists "$H/manuel/x"
  assert_contains "$OUT" "2 action(s) exécutée(s)"
  assert_contains "$OUT" "Actions PRUDENCE non proposées (pas de terminal interactif)."
}

test_sans_yes_les_actions_sures_attendent_le_oui_global() {
  _plan_main
  in_sandbox 'LOG_FILE="$MC_SANDBOX/journal"; DATA_VOL=/
    execute_plan "$MC_SANDBOX/plan" <<< "non"'
  assert_contains "$OUT" "Actions SÛRES ignorées."
  assert_exists "$H/caches/a-supprimer/x"
  in_sandbox 'LOG_FILE="$MC_SANDBOX/journal"; DATA_VOL=/
    execute_plan "$MC_SANDBOX/plan" <<< "oui"'
  assert_not_exists "$H/caches/a-supprimer"
}

test_prudence_jamais_sans_confirmation_individuelle_meme_avec_yes() {
  _plan_main
  # Terminal simulé ; --yes ; réponses : rien pour la première, « o » pour la seconde.
  in_sandbox 'is_interactive() { true; }
    LOG_FILE="$MC_SANDBOX/journal"; DATA_VOL=/; ASSUME_YES=1
    execute_plan "$MC_SANDBOX/plan" <<< $'"'"'\no'"'"
  assert_status 0
  assert_exists "$H/prudence/un/x"
  assert_not_exists "$H/prudence/deux"
  assert_contains "$OUT" "ignoré"
  # « q » arrête tout, même avec --yes.
  make_file "$H/prudence/deux/x" 4
  in_sandbox 'is_interactive() { true; }
    LOG_FILE="$MC_SANDBOX/journal"; DATA_VOL=/; ASSUME_YES=1
    execute_plan "$MC_SANDBOX/plan" <<< "q"'
  assert_exists "$H/prudence/un/x"; assert_exists "$H/prudence/deux/x"
  # Sans réponse du tout (fin d'entrée), rien n'est exécuté.
  in_sandbox 'is_interactive() { true; }
    LOG_FILE="$MC_SANDBOX/journal"; DATA_VOL=/; ASSUME_YES=1
    execute_plan "$MC_SANDBOX/plan" </dev/null'
  assert_exists "$H/prudence/un/x"; assert_exists "$H/prudence/deux/x"
}

test_plan_illisible() {
  in_sandbox 'show_plan "$MC_SANDBOX/absent"; print -r -- "rc=$?"'
  assert_contains "$OUT" "plan illisible : $MC_SANDBOX/absent"
  assert_contains "$OUT" "rc=1"
}
