# Règle de verdict git pour les worktrees des agents de code (issue #22).

# _g ARGS… : git isolé de la configuration de l'utilisateur.
_g() { GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -c user.name=t -c user.email=t@t -c init.defaultBranch=main "$@" >/dev/null 2>&1 || fail "git $*"; }

# _depots : un dépôt distant nu, un clone, et sous ~/wt un worktree par cas.
_depots() {
  local w
  _g init -q --bare "$H/distant.git"
  _g clone -q "$H/distant.git" "$H/depot"
  _g -C "$H/depot" commit -q --allow-empty -m init
  _g -C "$H/depot" push -q origin HEAD:main
  for w in propre recent sale nonpousse; do
    _g -C "$H/depot" worktree add -q -b "$w" "$H/wt/$w"
    print -r -- "$w" > "$H/wt/$w/fichier"
    _g -C "$H/wt/$w" add fichier; _g -C "$H/wt/$w" commit -q -m "$w"
    _g -C "$H/wt/$w" push -q -u origin "$w"
  done
  print -r -- "brouillon" > "$H/wt/sale/nouveau"
  _g -C "$H/wt/nonpousse" commit -q --allow-empty -m "local 1"
  _g -C "$H/wt/nonpousse" commit -q --allow-empty -m "local 2"
  _g -C "$H/depot" worktree add -q -b jamais "$H/wt/sansdistante"
  _g -C "$H/depot" worktree add -q --detach "$H/wt/detache"
  mkdir -p "$H/wt/pasunworktree"; print x > "$H/wt/pasunworktree/f"
  age_path "$H/wt" 200; age_path "$H/wt/recent" 2
}

_sonde_git() {
  in_sandbox 'CACHE_DAYS=30; SOURCES="
essai | npm | ~/wt/* | git | cache | git | - | cmd git -C {path} worktree remove {path} | {name} | taille_nulle
"
    taille_nulle() { print 20000; }
    probe_sources essai
    for (( i = 1; i <= ${#CAND_PATH}; i++ )); do
      print -r -- "${CAND_LABEL[i]}|${CAND_VERDICT[i]}|${CAND_REASON[i]}|$(describe_action "${CAND_ACTION[i]}")"
    done'
  assert_status 0
}

test_verdict_git_cas_par_cas() {
  _depots
  _sonde_git
  assert_contains "$OUT" "propre|caution|worktree propre et poussé, non modifié depuis ≥ 30 j|git -C $H/wt/propre worktree remove $H/wt/propre"
  assert_contains "$OUT" "recent|manual|worktree modifié il y a moins de 30 j|"
  assert_contains "$OUT" "sale|manual|modifications non commitées"
  assert_contains "$OUT" "nonpousse|manual|2 commit(s) non poussé(s)|"
  assert_contains "$OUT" "sansdistante|manual|pas de branche distante"
  assert_contains "$OUT" "detache|manual|HEAD détaché"
  assert_contains "$OUT" "pasunworktree|manual|pas un worktree git"
  assert_not_contains "$OUT" "|safe|"
}

test_le_depot_principal_n_est_pas_un_worktree() {
  _depots
  in_sandbox 'git_verdict "$HOME/depot" 30; git_verdict "$HOME/wt/propre/sous" 30'
  [[ "$OUT" == $'manual|pas un worktree git (ou dépôt parent introuvable)\nmanual|pas un worktree git (ou dépôt parent introuvable)' ]] || fail "obtenu :"$'\n'"$OUT"
}

test_depot_parent_disparu() {
  _depots
  rm -rf "$H/depot"
  in_sandbox 'git_verdict "$HOME/wt/propre" 30'
  [[ "$OUT" == "manual|pas un worktree git (ou dépôt parent introuvable)" ]] || fail "obtenu : $OUT"
}

test_sans_git_les_lignes_git_sont_ignorees() {
  mkdir -p "$H/wt/x"
  rm -f "$MC_SANDBOX/bin/git"
  _sonde_git
  [[ -z "$OUT" ]] || fail "obtenu : $OUT"
}

test_l_action_retire_le_worktree_propre() {
  _depots
  in_sandbox 'run_action "$(new_action cmd git -C "$HOME/wt/propre" worktree remove "$HOME/wt/propre")"; print rc=$?
    run_action "$(new_action cmd git -C "$HOME/wt/sale" worktree remove "$HOME/wt/sale")" 2>/dev/null; print rc=$?'
  assert_not_exists "$H/wt/propre"
  assert_exists "$H/wt/sale/nouveau"
  assert_contains "$OUT" "rc=0"
}
