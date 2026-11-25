# Section agents, age! à plusieurs noms, briques T3 Code et Hugging Face (issue #23).

_g() { GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -c user.name=t -c user.email=t@t -c init.defaultBranch=main "$@" >/dev/null 2>&1 || fail "git $*"; }

# _sonde SECTION : « catégorie|libellé|verdict|raison|action décrite » par candidat.
_sonde() {
  in_sandbox 'CACHE_DAYS=30; MODEL_DAYS=90; probe_sources '"$1"' >/dev/null
    for (( i = 1; i <= ${#CAND_PATH}; i++ )); do
      print -r -- "${CAND_CAT[i]}|${CAND_LABEL[i]}|${CAND_VERDICT[i]}|${CAND_REASON[i]}|$(describe_action "${CAND_ACTION[i]}")"
    done'
  assert_status 0
}

_t3() {
  make_file "$H/.t3/userdata/logs/vieux.log" 12288 200
  make_file "$H/.t3/userdata/logs/neuf.log" 100 0
  make_file "$H/.t3/userdata/statev2.sqlite" 60000 200
  make_file "$H/.t3/caches/c" 12288 200
  make_file "$H/.t3/tools/chrome/bin" 110000 200
  # Un worktree d'agent : ~/.t3/worktrees/<projet>/<worktree>, non poussé.
  _g init -q "$H/depot"; _g -C "$H/depot" commit -q --allow-empty -m init
  mkdir -p "$H/.t3/worktrees/projet"
  _g -C "$H/depot" worktree add -q -b agent "$H/.t3/worktrees/projet/agent-1"
  make_file "$H/.t3/worktrees/projet/agent-1/gros" 12288 200
  _g -C "$H/.t3/worktrees/projet/agent-1" add gros
  _g -C "$H/.t3/worktrees/projet/agent-1" commit -q -m gros
  age_path "$H/.t3" 200; age_path "$H/.t3/userdata/logs/neuf.log" 0
}

test_brique_t3_code() {
  _t3
  _sonde agents
  assert_contains "$OUT" "t3code|~/.t3/userdata/logs (fichiers > 30 j)|safe|journaux anciens"
  assert_contains "$OUT" "|supprimer les fichiers > 30 j dans ~/.t3/userdata/logs"
  assert_contains "$OUT" "t3code|caches de T3 Code|safe|non modifié depuis ≥ 30 j"
  assert_contains "$OUT" "t3code|~/.t3/worktrees/projet/agent-1|manual|pas de branche distante"
  assert_contains "$OUT" "|git -C $H/.t3/worktrees/projet/agent-1 worktree remove $H/.t3/worktrees/projet/agent-1"
  assert_contains "$OUT" "t3code|outils téléchargés par T3 Code (navigateur, agents)|manual|"
  assert_not_contains "$OUT" "sqlite"
  assert_not_contains "$OUT" "|~/.t3/userdata|"
}

test_t3_code_ouvert_sous_l_un_ou_l_autre_nom() {
  _t3
  local nom
  for nom in "T3 Code" "T3 Code (Beta)"; do
    print -r -- "$nom" > "$MC_SANDBOX/running"
    _sonde agents
    assert_contains "$OUT" "t3code|caches de T3 Code|caution|T3 Code est ouvert : fermez-le avant"
  done
}

test_is_running_protege_le_nom_et_compte_les_ancetres() {
  fake_tool pgrep 'exit 1'
  in_sandbox 'is_running "T3 Code (Beta)"; is_running "a.b|c"'
  [[ "$(argv_of pgrep)" == "$(quoted -a -x -- 'T3 Code \(Beta\)')"$'\n'"$(quoted -a -x -- 'a\.b\|c')" ]] \
    || fail "obtenu :"$'\n'"$(argv_of pgrep)"
}

test_section_agents_de_bout_en_bout() {
  _t3
  run_script --dry-run --skip-spotlight --lang en
  assert_status 0
  assert_contains "$OUT" "Coding agents"
  assert_contains "$(section 'A. SAFE')" "T3 Code caches"
  assert_contains "$(section 'C. MANUAL')" "no remote branch: work never pushed"
}

test_brique_hugging_face() {
  make_file "$H/.cache/huggingface/datasets/squad___plain_text/d.arrow" 60000; age_path "$H/.cache/huggingface/datasets/squad___plain_text" 200
  make_file "$H/.cache/huggingface/datasets/recent___x/d.arrow" 60000; age_path "$H/.cache/huggingface/datasets/recent___x" 2
  make_file "$H/.cache/huggingface/xet/chunk-cache/c" 12288 200
  make_file "$H/.cache/huggingface/token" 1 200
  age_path "$H/.cache/huggingface/xet" 200
  _sonde models
  assert_contains "$OUT" "hf_datasets|squad___plain_text|caution|non touché depuis 200 j ≥ 90 j ; retéléchargeable|supprimer ~/.cache/huggingface/datasets/squad___plain_text"
  assert_contains "$OUT" "hf_datasets|recent___x|manual|récent (2 j)"
  assert_contains "$OUT" "huggingface|cache Xet Hugging Face (morceaux de fichiers)|safe|"
  assert_not_contains "$OUT" "token"
  # Le scan de ~/.cache ne les compte pas une deuxième fois.
  in_sandbox 'probe_cli_caches >/dev/null; print -r -- "n=${#CAND_PATH}"'
  [[ "$OUT" == "n=0" ]] || fail "obtenu : $OUT"
}
