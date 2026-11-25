# Sondes sur mesure enregistrées dans PROBES, lancées par run_section (issue #21).

test_une_sonde_enregistree_passe_par_le_filet() {
  in_sandbox '
    ACTIVE_PROJECTS=("$HOME/projet")
    probe_essai() {
      add_candidate npm "dans le projet" "$HOME/projet/cache" 1 999 safe "raison" "$(new_action rm-path "$HOME/projet/cache")"
      add_candidate npm "ailleurs" "$HOME/ailleurs" 1 999 safe "raison" none
    }
    SOURCES=""; PROBES+=(essai:probe_essai)
    run_section essai
    for (( i = 1; i <= ${#CAND_PATH}; i++ )); do print -r -- "${CAND_LABEL[i]}|${CAND_VERDICT[i]}"; done'
  assert_status 0
  [[ "$OUT" == $'dans le projet|caution\nailleurs|safe' ]] || fail "obtenu :"$'\n'"$OUT"
}

test_ordre_catalogue_et_sondes() {
  make_file "$H/a/x" 12288 200
  in_sandbox '
    SOURCES="
essai | npm | ~/a | - | cache | safe | reason.redownloaded | none | catalogue | du
"
    probe_un() { add_candidate npm sonde1 "$HOME/s1" 1 0 safe r none; }
    probe_deux() { add_candidate npm sonde2 "$HOME/s2" 1 0 safe r none; }
    PROBES=(essai:probe_un essai:probe_deux); run_section essai; print -r -- "${(j:,:)CAND_LABEL}"
    CAND_LABEL=()
    PROBES=(essai:probe_un essai:catalogue essai:probe_deux); run_section essai; print -r -- "${(j:,:)CAND_LABEL}"'
  assert_status 0
  # Sans « catalogue » dans PROBES : les lignes du catalogue d abord.
  [[ "$OUT" == $'catalogue,sonde1,sonde2\nsonde1,catalogue,sonde2' ]] || fail "obtenu :"$'\n'"$OUT"
}

test_les_sondes_enregistrees_existent() {
  in_sandbox '
    for e in "${PROBES[@]}"; do
      f="${e#*:}"; [[ "$f" == catalogue ]] || whence -w "$f" >/dev/null || print -r -- "absente : $f"
    done'
  assert_status 0
  [[ -z "$OUT" ]] || fail "$OUT"
}

test_sonde_dont_l_outil_est_absent() {
  # docker et ollama sont absents du bac à sable : leurs sondes ne font rien.
  in_sandbox 'probe_docker; probe_ollama; print -r -- "n=${#CAND_PATH}"'
  assert_status 0
  [[ "$OUT" == "n=0" ]] || fail "obtenu : $OUT"
}

test_docker_est_une_sonde() {
  fake_tool docker 'case "$1" in info) exit 0;; system) [[ "$*" == *format* ]] && print "1.2GB (40%)";; esac'
  run_script --dry-run --skip-spotlight --lang fr
  assert_status 0
  assert_contains "$(section 'B. PRUDENCE')" "→ docker system prune -f"
}
