# Catalogues de messages complets en français et en anglais (issue #19).
#
# Une clé absente ne fait pas planter le script : m affiche « [clé] » à la
# place du texte. Ces tests sont donc le seul garde-fou. Les clés citées par le
# catalogue de sources (catégorie, raison, libellé @…, age!App=clé) sont
# vérifiées par test_le_catalogue_est_bien_forme (test_catalogue.zsh).

test_les_deux_langues_ont_les_memes_cles() {
  in_sandbox '
    messages_fr; fr=(${(ok)MSG})
    messages_en; en=(${(ok)MSG})
    for k in ${fr:|en}; do print -r -- "manque en anglais : $k"; done
    for k in ${en:|fr}; do print -r -- "manque en français : $k"; done'
  assert_status 0
  [[ -z "$OUT" ]] || fail "$OUT"
}

test_chaque_cle_citee_par_le_code_existe() {
  # Appels littéraux « m clé.sous_clé » dans le script.
  local -a keys; keys=(${(u)${(f)"$(grep -oE '\bm [a-z_]+\.[a-z_.]+' "$SCRIPT" | cut -c3-)"}})
  (( ${#keys} > 50 )) || fail "trop peu de clés trouvées (${#keys}) : l'extraction est cassée ?"
  in_sandbox '
    for lang in fr en; do
      messages_$lang
      for k in '"${(j: :)${(@q)keys}}"'; do
        [[ -n "${MSG[$k]-}" ]] || print -r -- "manque ($lang) : $k"
      done
    done'
  assert_status 0
  [[ -z "$OUT" ]] || fail "$OUT"
}

test_le_controle_du_catalogue_nomme_la_cle_et_la_langue() {
  # Une source dont la raison et le libellé n'existent dans aucune langue, et
  # une catégorie qui n'existe qu'en français.
  in_sandbox 'SOURCES+="
pkg | npm      | ~/x | - | cache | safe | cle.inexistante | none | @autre.inexistante | du
pkg | demi_cat | ~/y | - | cache | safe | -               | none | Y                  | du
"
    messages_fr() { MSG=(cat.npm npm cat.demi_cat demi) }
    messages_en() { MSG=(cat.npm npm) }
    '"$CATALOGUE_CHECK"
  assert_contains "$OUT" "raison cle.inexistante (fr)"
  assert_contains "$OUT" "raison cle.inexistante (en)"
  assert_contains "$OUT" "libellé @autre.inexistante (en)"
  assert_contains "$OUT" "cat.demi_cat (en)"
  assert_not_contains "$OUT" "cat.demi_cat (fr)"
}
