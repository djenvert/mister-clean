# Brique Orca (issue #24). Emplacements tirés du code source d'Orca, pas d'une
# vraie installation : ces tests fixent ce que la brique propose et, surtout,
# ce qu'elle ne propose jamais.

_g() { GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -c user.name=t -c user.email=t@t -c init.defaultBranch=main "$@" >/dev/null 2>&1 || fail "git $*"; }

_sonde() {
  in_sandbox 'CACHE_DAYS=30; MODEL_DAYS=90; probe_sources agents >/dev/null
    for (( i = 1; i <= ${#CAND_PATH}; i++ )); do
      print -r -- "${CAND_CAT[i]}|${CAND_LABEL[i]}|${CAND_VERDICT[i]}|${CAND_REASON[i]}|$(describe_action "${CAND_ACTION[i]}")"
    done'
  assert_status 0
}

_orca() {
  local A="$H/Library/Application Support/Orca"
  make_file "$A/logs/orca.log.1" 12288 200
  make_file "$A/terminal-history/s1/h" 12288 200
  make_file "$A/terminal-scrollback/s1/b" 12288 200
  make_file "$A/speech-models/whisper-base/m.bin" 60000; age_path "$A/speech-models/whisper-base" 200
  make_file "$A/Partitions/orca-browser/x" 110000 200
  make_file "$A/Code Cache/js/x" 110000 200
  make_file "$A/orchestration.db" 60000 200
  make_file "$A/bot-work.sqlite" 60000 200
  make_file "$A/profiles/p1/profile-state.db" 60000 200
  make_file "$H/.orca/google/credentials.json" 12288 200
  # Un worktree d'agent avec du travail non poussé, rangé par dépôt.
  _g init -q --bare "$H/distant.git"; _g clone -q "$H/distant.git" "$H/depot"
  _g -C "$H/depot" commit -q --allow-empty -m init; _g -C "$H/depot" push -q origin HEAD:main
  mkdir -p "$H/orca/workspaces/depot"
  _g -C "$H/depot" worktree add -q -b agent "$H/orca/workspaces/depot/agent-1"
  _g -C "$H/orca/workspaces/depot/agent-1" push -q -u origin agent
  make_file "$H/orca/workspaces/depot/agent-1/gros" 12288 200
  _g -C "$H/orca/workspaces/depot/agent-1" add gros
  _g -C "$H/orca/workspaces/depot/agent-1" commit -q -m gros
  age_path "$H/orca" 200
}

test_brique_orca() {
  _orca
  _sonde
  assert_contains "$OUT" "orca|~/orca/workspaces/depot/agent-1|manual|1 commit(s) non poussé(s)|git -C $H/orca/workspaces/depot/agent-1 worktree remove"
  assert_contains "$OUT" "orca|~/Library/Application Support/Orca/logs (fichiers > 30 j)|safe|"
  assert_contains "$OUT" "orca|historique des terminaux Orca (terminal-history)|safe|non modifié depuis ≥ 30 j"
  assert_contains "$OUT" "orca|historique des terminaux Orca (terminal-scrollback)|safe|"
  assert_contains "$OUT" "model_orca|whisper-base|caution|non touché depuis 200 j ≥ 90 j ; retéléchargeable"
  assert_contains "$OUT" "orca|navigateur intégré d'Orca (Partitions)|manual|"
  assert_contains "$OUT" "orca|navigateur intégré d'Orca (Code Cache)|manual|"
}

test_orca_ouvert() {
  _orca
  print Orca > "$MC_SANDBOX/running"
  _sonde
  assert_contains "$OUT" "orca|historique des terminaux Orca (terminal-history)|caution|Orca est ouvert : fermez-le avant"
}

test_orca_ne_propose_jamais_les_bases_ni_les_identifiants() {
  _orca
  run_script --dry-run --skip-spotlight --lang fr
  assert_status 0
  local -a f; f=($H/Library/Logs/mister-clean/run-*.plan(N))
  (( ${#f} == 1 )) || fail "plan introuvable"
  local plan; plan="$(<$f[1])"
  assert_not_contains "$plan" ".orca"
  assert_not_contains "$plan" ".db"
  assert_not_contains "$plan" ".sqlite"
  assert_not_contains "$plan" "profiles"
  assert_contains "$plan" "Orca/logs"
}
