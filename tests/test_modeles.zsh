# Une seule règle de verdict pour les modèles IA (issue #5) : récent → conservé
# (MANUEL), ancien → PRUDENCE, chargé ou en conflit → PRUDENCE ; jamais SÛR.

# --- La règle seule ------------------------------------------------------------

# _regle CODE : charge le script, exécute CODE (appels à add_model), affiche
# « verdict|raison » pour chaque candidat.
_regle() {
  in_sandbox "$1"'
    for i in {1..${#CAND_PATH}}; do print -r -- "${CAND_VERDICT[i]}|${CAND_REASON[i]}"; done'
  assert_status 0
}

test_regle_recent_ancien_charge() {
  _regle 'MODEL_DAYS=90
    add_model model_huggingface r "$HOME/r" 1 89 0 "ancien r" none
    add_model model_huggingface a "$HOME/a" 1 90 0 "ancien a" none
    add_model model_ollama c "ollama:c" 1 3 1 "ancien c" none
    add_model model_ollama v "ollama:v" 1 400 1 "ancien v" none'
  [[ "$OUT" == $'manual|récent (89 j) — conservé\ncaution|ancien a\ncaution|actuellement chargé en mémoire\ncaution|actuellement chargé en mémoire' ]] \
    || fail "obtenu :"$'\n'"$OUT"
}

test_regle_modele_en_conflit() {
  _regle 'MODEL_DAYS=90; OPEN_FILES=("$HOME/m/poids.bin")
    add_model model_torch m "$HOME/m" 1 200 0 "ancien" none'
  [[ "$OUT" == "caution|fichier ouvert par un processus : poids.bin" ]] || fail "obtenu : $OUT"
}

test_les_caches_laissent_les_modeles_a_leur_regle() {
  in_sandbox '
    for d in huggingface torch whisper lm-studio outil; do is_model_area "$HOME/.cache/$d" && print -r -- "modèles:$d"; done
    is_model_area "$HOME/.lmstudio" && print modèles:.lmstudio'
  [[ "$OUT" == $'modèles:huggingface\nmodèles:torch\nmodèles:whisper\nmodèles:lm-studio\nmodèles:.lmstudio' ]] || fail "obtenu :"$'\n'"$OUT"
}

# --- De bout en bout, toutes sources ----------------------------------------

# Faux ollama : « list » donne un modèle de 5 mois (150 j), un récent et un
# ancien chargé ; « ps » donne le modèle chargé.
_faux_ollama() {
  local f="$MC_SANDBOX/bin/ollama"
  cat > "$f" <<'SH'
#!/bin/zsh -f
case "$1" in
  list) print "NAME ID SIZE MODIFIED"
        print "vieux:7b aaa 4.1 GB 5 months ago"
        print "neuf:7b bbb 2.0 GB 2 days ago"
        print "charge:7b ccc 1.0 GB 1 year ago" ;;
  ps)   print "NAME ID SIZE PROCESSOR UNTIL"
        print "charge:7b ccc 1.0 GB 100% GPU 4 minutes from now" ;;
esac
SH
  chmod +x "$f"
}

_modeles() {
  _faux_ollama
  make_file "$H/.cache/huggingface/hub/models--vieux/poids.bin" 60000; age_path "$H/.cache/huggingface" 150
  make_file "$H/.cache/huggingface/hub/models--neuf/poids.bin" 60000; age_path "$H/.cache/huggingface/hub/models--neuf" 2
  make_file "$H/.lmstudio/models/lms-vieux/poids.gguf" 60000; age_path "$H/.lmstudio" 150
  make_file "$H/.cache/whisper/ouvert/poids.pt" 60000; age_path "$H/.cache/whisper" 300
  print -r -- "$H/.cache/whisper/ouvert/poids.pt" > "$MC_SANDBOX/open_files"
}

test_bout_en_bout_toutes_les_sources_suivent_la_regle() {
  _modeles
  run_script --dry-run --skip-spotlight --lang fr --model-days 150
  assert_status 0
  local safe caution manuel
  safe="$(section 'A. SÛR')"; caution="$(section 'B. PRUDENCE')"; manuel="$(section 'C. MANUEL')"
  # Jamais SÛR, et huggingface n'est plus pris pour un cache CLI.
  assert_not_contains "$safe" "Modèle"
  assert_not_contains "$OUT" "Cache CLI"
  assert_contains "$caution" "pull il y a 150 j ≥ 150 j ; ollama pull vieux:7b pour le ravoir"
  assert_contains "$(print -r -- "$caution" | grep models--vieux)" "non touché depuis 150 j ≥ 150 j ; retéléchargeable"
  assert_contains "$(print -r -- "$caution" | grep lms-vieux)" "non touché depuis 150 j ≥ 150 j"
  assert_contains "$(print -r -- "$caution" | grep charge:7b)" "actuellement chargé en mémoire"
  assert_contains "$(print -r -- "$caution" | grep ouvert)" "fichier ouvert par un processus : poids.pt"
  assert_contains "$(print -r -- "$manuel" | grep neuf:7b)" "récent (2 j) — conservé"
  assert_contains "$(print -r -- "$manuel" | grep models--neuf)" "récent (2 j) — conservé"
}

test_bout_en_bout_le_seuil_vaut_pour_toutes_les_sources() {
  _modeles
  run_script --dry-run --skip-spotlight --lang fr --model-days 151
  local manuel; manuel="$(section 'C. MANUEL')"
  assert_contains "$(print -r -- "$manuel" | grep vieux:7b)" "récent (150 j) — conservé"
  assert_contains "$(print -r -- "$manuel" | grep models--vieux)" "récent (150 j) — conservé"
  assert_contains "$(print -r -- "$manuel" | grep lms-vieux)" "récent (150 j) — conservé"
  # Chargé ou en conflit : PRUDENCE quel que soit le seuil.
  assert_contains "$(section 'B. PRUDENCE' | grep charge:7b)" "actuellement chargé"
  assert_contains "$(section 'B. PRUDENCE' | grep ouvert)" "fichier ouvert"
}
