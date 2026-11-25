# mister-clean

Audit disque macOS en un script zsh : contre-vérification de l'index Spotlight,
scan des caches inutilisés et des anciens modèles IA, gros volumes, protection
des projets en cours, puis plan de nettoyage.

```sh
./mister-clean.sh --dry-run   # audit + plan, aucune suppression
./mister-clean.sh             # audit + plan, confirmation, exécution
./mister-clean.sh --help      # options (--days, --model-days, --fast, --yes, --lang…)
```

Lancez-le depuis Terminal.app avec l'« Accès complet au disque » accordé
(Réglages > Confidentialité et sécurité), sinon `mdfind` est bridé et les
tests Spotlight sont marqués NON CONCLUANTS. `sudo -v` juste avant permet
de mesurer la taille de l'index système.

Chaque exécution est journalisée dans `~/Library/Logs/mister-clean/`, avec
son plan de nettoyage (`run-….plan`) : un candidat par ligne (verdict,
catégorie, taille, âge, libellé, raison, chemin, action). Le format est décrit
dans le script, section « 6. Plan de nettoyage ». L'affichage et l'exécution
ne lisent que ce plan.

## Langue / Language

Un seul script, en français ou en anglais. La langue ne change que les
messages, jamais ce que fait le script.

- `--lang fr` ou `--lang en` choisit la langue (aide comprise).
- Sans `--lang`, la langue vient de la locale : la première variable non vide
  parmi `LC_ALL`, `LC_MESSAGES` puis `LANG`. `fr…` donne le français,
  tout le reste l'anglais.
- Repli : anglais si aucune de ces variables n'est définie, ou si elle vaut
  `C`, `POSIX` ou une autre langue.

En anglais, les verdicts sont SAFE / CAUTION / MANUAL et le mot de
confirmation est `yes` (au lieu de SÛR / PRUDENCE / MANUEL et `oui`).

One script, in French or English. `--lang en` forces English; without it,
the language comes from `LC_ALL`, `LC_MESSAGES` or `LANG` (first non-empty
one), falling back to English. Verdicts are SAFE / CAUTION / MANUAL and the
confirmation word is `yes`.

```sh
./mister-clean.sh --lang en --dry-run
./mister-clean.sh --lang en
```

## Tests

```sh
./tests/run.zsh                          # toute la suite
./tests/run.zsh tests/test_harnais.zsh   # un seul fichier
```

Les tests ne touchent jamais au vrai disque. Chaque test tourne dans son
propre processus, avec un bac à sable neuf (voir `tests/lib.zsh`) :

- un `HOME` jetable, créé dans le répertoire temporaire puis supprimé ;
- un `PATH` réduit à une liste d'outils système autorisés et aux outils
  simulés de `tests/stubs/` (`df`, `diskutil`, `tmutil`, `lsof`, `pgrep`…).
  Les outils absents (brew, docker, ollama…) le sont aussi pour le script ;
- le seul dossier système que le script nettoie (`/Library/Logs/DiagnosticReports`)
  est remplacé par un dossier du bac à sable, via `MISTER_CLEAN_SYSTEM_LOGS` ;
- `sudo`, `mdutil`, `mdfind` et `log` sont simulés : ils échouent sans rien
  faire et chaque appel est noté. Les tests passent `--skip-spotlight` et
  vérifient qu'aucun n'a été appelé. Ni sudo ni l'Accès complet au disque ne
  sont nécessaires.

Le script peut être chargé sans rien lancer : `source mister-clean.sh` définit
ses fonctions et ses réglages par défaut ; l'audit ne démarre que lorsque le
script est exécuté. Un test peut ainsi soit lancer le script entier
(`run_script --dry-run …`), soit appeler ses fonctions (`in_sandbox '…'`).

Pour écrire un test : ajouter une fonction `test_…` dans un fichier
`tests/test_*.zsh`, construire le `HOME` avec `make_file` et `age_path`, puis
vérifier avec les `assert_*` de `tests/lib.zsh`.
