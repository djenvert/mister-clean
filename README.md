# mister-clean

Audit disque macOS en un script zsh : contre-vérification de l'index Spotlight,
scan des caches inutilisés et des anciens modèles IA, gros volumes, protection
des projets en cours, puis plan de nettoyage.

```sh
./mister-clean.sh --dry-run   # audit + plan, aucune suppression
./mister-clean.sh             # audit + plan, confirmation, exécution
./mister-clean.sh --help      # options (--days, --model-days, --fast, --yes…)
```

Lancez-le depuis Terminal.app avec l'« Accès complet au disque » accordé
(Réglages > Confidentialité et sécurité), sinon `mdfind` est bridé et les
tests Spotlight sont marqués NON CONCLUANTS. `sudo -v` juste avant permet
de mesurer la taille de l'index système.

Chaque exécution est journalisée dans `~/Library/Logs/mister-clean/`.

## English version

`mister-clean-en.sh` is the same script with English comments and messages.
Verdicts are SAFE / CAUTION / MANUAL and the confirmation word is `yes`.

```sh
./mister-clean-en.sh --dry-run
./mister-clean-en.sh
```
