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

Chaque exécution est journalisée dans `~/Library/Logs/mister-clean/`.

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
