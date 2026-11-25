# Catalogue de sources lu par un seul sondeur (issue #8).

# _sonde CODE SECTION : charge le script, exécute CODE puis probe_sources
# SECTION, et affiche « libellé|verdict|raison|taille|action décrite » par candidat.
_sonde() {
  in_sandbox "$1"'
    probe_sources '"$2"'
    for (( i = 1; i <= ${#CAND_PATH}; i++ )); do
      print -r -- "${CAND_LABEL[i]}|${CAND_VERDICT[i]}|${CAND_REASON[i]}|${CAND_KB[i]}|$(describe_action "${CAND_ACTION[i]}")"
    done'
  assert_status 0
}

test_ajouter_une_entree_suffit() {
  make_file "$H/.outil-neuf/cache/blob" 12288 200
  _sonde 'SOURCES+="
pkg | npm | ~/.outil-neuf/cache | - | cache | safe | reason.redownloaded | rm-contents {path} | Outil neuf ({name}) | du
"' pkg
  [[ "$OUT" == "Outil neuf (cache)|safe|retéléchargé à la demande|"*"|vider ~/.outil-neuf/cache/" ]] || fail "obtenu : $OUT"
}

test_le_seuil_est_un_minimum_inclus() {
  mkdir -p "$H/a" "$H/b"
  _sonde 'taille_fixe() { [[ $1 == */a ]] && print 10240 || print 10239; }
SOURCES="
pkg | npm | ~/a | - | cache | safe | reason.redownloaded | none | A | taille_fixe
pkg | npm | ~/b | - | cache | safe | reason.redownloaded | none | B | taille_fixe
"' pkg
  [[ "$OUT" == "A|safe|retéléchargé à la demande|10240|" ]] || fail "obtenu : $OUT"
}

test_emplacement_donne_par_l_outil() {
  make_file "$H/magasin/x" 12288 200
  _sonde 'SOURCES="
pkg | pnpm | \$ pnpm store path | pnpm | cache | safe | pnpm.reason | cmd pnpm store prune | @pnpm.label | du
"' pkg
  [[ -z "$OUT" ]] || fail "outil absent : la source devait être ignorée, obtenu : $OUT"
  fake_tool pnpm '[[ "$*" == "store path" ]] && print -r -- "$HOME/magasin"'
  _sonde 'SOURCES="
pkg | pnpm | \$ pnpm store path | pnpm | cache | safe | pnpm.reason | cmd pnpm store prune | @pnpm.label | du
"' pkg
  assert_contains "$OUT" "store pnpm (paquets orphelins)|safe|"
  assert_contains "$OUT" "|pnpm store prune"
}

test_joker_un_candidat_par_dossier() {
  make_file "$H/Library/Developer/Xcode/iOS DeviceSupport/x" 12288 200
  make_file "$H/Library/Developer/Xcode/tvOS DeviceSupport/x" 12288 200
  _sonde '' dev
  assert_contains "$OUT" "iOS DeviceSupport (symboles d'anciens OS)|safe|"
  assert_contains "$OUT" "tvOS DeviceSupport (symboles d'anciens OS)|safe|"
  assert_contains "$OUT" "vider ~/Library/Developer/Xcode/iOS DeviceSupport/"
}

test_verdict_selon_l_age_et_application_ouverte() {
  make_file "$H/Library/Developer/Xcode/DerivedData/P/x" 12288; age_path "$H/Library/Developer/Xcode/DerivedData" 200
  _sonde '' dev
  assert_contains "$OUT" "DerivedData (builds intermédiaires)|safe|non modifié depuis ≥ 30 j"
  print Xcode > "$MC_SANDBOX/running"
  _sonde '' dev
  assert_contains "$OUT" "DerivedData (builds intermédiaires)|caution|Xcode est ouvert : fermez-le avant"
}

test_pip_dans_son_emplacement_par_defaut_est_propose() {
  # Avant le catalogue, ~/Library/Caches/pip était écarté des deux côtés
  # (scan des caches et source pip) et n'était donc jamais proposé.
  make_file "$H/Library/Caches/pip/http/x" 12288 200; age_path "$H/Library/Caches/pip" 200
  fake_tool pip3 '[[ "$*" == "cache dir" ]] && print -r -- "$HOME/Library/Caches/pip"'
  run_script --dry-run --skip-spotlight --lang fr
  local safe; safe="$(section 'A. SÛR')"
  assert_contains "$safe" "cache pip"
  assert_contains "$safe" "→ pip3 cache purge"
  assert_not_contains "$safe" "vider ~/Library/Caches/pip/"
}

test_le_catalogue_est_bien_forme() {
  in_sandbox "$CATALOGUE_CHECK"
  [[ "$OUT" == "entrées=22" ]] || fail "catalogue :"$'\n'"$OUT"
}
