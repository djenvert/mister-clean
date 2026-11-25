# Tests du harnais lui-même : chargement sans effet et premier bout en bout.

# Un cache de 12 Mio que personne n'a touché depuis 200 jours.
_cache_ancien() {
  CACHE="$H/Library/Caches/com.example.ancien"
  make_file "$CACHE/blob.bin" 12288
  age_path "$CACHE" 200
}

test_charger_le_script_ne_lance_rien() {
  in_sandbox 'whence -w main parse_args verdict_for add_candidate run_action; print -r -- "candidats=${#CAND_PATH}"'
  assert_status 0
  assert_contains "$OUT" "main: function"
  assert_contains "$OUT" "run_action: function"
  assert_contains "$OUT" "candidats=0"
  assert_not_contains "$OUT" "━━━"
  [[ ! -s "$MC_SANDBOX/calls" ]] || fail "outils appelés au chargement : $(<$MC_SANDBOX/calls)"
  assert_not_exists "$H/Library/Logs/mister-clean"
}

test_charger_avec_des_arguments_ne_lance_rien() {
  in_sandbox "source ${(q)SCRIPT} --dry-run --yes; "'print -r -- "dry=$DRY_RUN yes=$ASSUME_YES"'
  assert_status 0
  assert_contains "$OUT" "dry=0 yes=0"
  [[ ! -s "$MC_SANDBOX/calls" ]] || fail "outils appelés au chargement : $(<$MC_SANDBOX/calls)"
}

test_dry_run_cache_ancien_est_sur_fr() {
  _cache_ancien
  run_script --dry-run --skip-spotlight --lang fr
  assert_status 0
  local safe; safe="$(section 'A. SÛR')"
  assert_contains "$safe" "com.example.ancien"
  assert_contains "$safe" "non modifié depuis ≥ 30 j, régénérable"
  assert_contains "$safe" "→ vider ~/Library/Caches/com.example.ancien/"
  assert_contains "$OUT" "Mode --dry-run : rien n'a été supprimé."
  assert_not_contains "$OUT" "7. Exécution"
  # Rien n'est supprimé.
  assert_exists "$CACHE/blob.bin"
  # Le script a bien travaillé dans le HOME jetable : son journal y est.
  [[ -n "$(print -r -- $H/Library/Logs/mister-clean/run-*.log(N))" ]] || fail "journal absent du HOME de test"
  # Ni sudo, ni Spotlight.
  assert_not_contains "$OUT" "Spotlight — "
  assert_not_called sudo; assert_not_called mdutil; assert_not_called mdfind; assert_not_called log
}

test_dry_run_cache_ancien_est_sur_en() {
  _cache_ancien
  run_script --dry-run --skip-spotlight --lang en
  assert_status 0
  local safe; safe="$(section 'A. SAFE')"
  assert_contains "$safe" "com.example.ancien"
  assert_contains "$safe" "→ empty ~/Library/Caches/com.example.ancien/"
  assert_exists "$CACHE/blob.bin"
  assert_not_called sudo
}
