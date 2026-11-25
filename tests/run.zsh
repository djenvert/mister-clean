#!/bin/zsh -f
# Lance la suite de tests : ./tests/run.zsh [FICHIER_DE_TEST…]
#
# Chaque fonction test_* de tests/test_*.zsh s'exécute dans un processus zsh
# séparé, avec un HOME jetable neuf (voir tests/lib.zsh). Aucun test ne touche
# au vrai HOME, ne demande sudo, ni n'interroge Spotlight.

emulate -L zsh
setopt null_glob

TESTS_DIR="${0:A:h}"
files=("$@")
(( $#files )) || files=("$TESTS_DIR"/test_*.zsh)

pass=0; failed=()
for f in $files; do
  print -r -- "${f:t}"
  for t in ${(f)"$(zsh -f -c "source ${(q)f:A}; print -l \${(k)functions[(I)test_*]}" | sort)"}; do
    if zsh -f -c "source ${(q)TESTS_DIR}/lib.zsh; source ${(q)f:A}; sandbox_new; trap 'rm -rf \"\$MC_SANDBOX\"' EXIT; $t"; then
      print -r -- "  ok    $t"; (( pass++ ))
    else
      print -r -- "  ÉCHEC $t"; failed+=("${f:t}:$t")
    fi
  done
done

print
if (( $#failed )); then
  print -r -- "$pass réussi(s), ${#failed} échoué(s) : ${(j:, :)failed}"
  exit 1
fi
print -r -- "$pass réussi(s)"
