# Ajouter une source à mister-clean

Une **source**, ou brique, est un ensemble de fichiers qu'un outil ou une app
laisse sur le disque et que mister-clean doit savoir mesurer, classer et
éventuellement nettoyer. Ce guide explique comment en ajouter une. Il
s'adresse aux humains comme aux agents IA, et peut se suivre sans lire le
reste du script.

Tout se passe dans `mister-clean.sh` (catalogue, messages, éventuellement une
sonde) et dans `tests/`. Il n'y a pas de fichier de configuration
utilisateur : une source s'ajoute par une PR.

## Ce qu'il faut savoir avant de commencer

- **Le script ne supprime jamais rien de lui-même.** Une source propose des
  **candidats** (chemin, taille, âge, verdict, raison, action). Le plan les
  range en trois groupes :
  - **safe** (SÛR) : exécuté après une seule confirmation, ou sans
    confirmation avec `--yes` ;
  - **caution** (PRUDENCE) : demandé un par un, jamais exécuté par `--yes` ;
  - **manual** (MANUEL) : affiché pour information, jamais exécuté.
- **Le filet de sécurité est automatique.** `add_candidate` passe en
  caution tout candidat qui touche un projet en cours ou un fichier ouvert.
  Une source n'a rien à faire pour en bénéficier, mais elle ne doit jamais
  le contourner.
- **Toute suppression de fichiers passe par `deletion_guard`.** Ce garde
  refuse les chemins relatifs, les liens symboliques, `~` lui-même et tout ce
  qui sort de `~`.

## 1. Choisir le type de brique

```
L'emplacement est-il connu (fixe, ou donné par une commande de l'outil) ?
├── oui ─ Un seul candidat pour tout le dossier ?
│         ├── oui ─────────────────────────────────── T1 : une ligne
│         └── non, un candidat par sous-dossier ───── T2 : une ligne avec joker
│                                                     + une règle de verdict
└── non : l'outil liste lui-même ses objets
          (ollama list, docker system df, tmutil…),
          ou il faut chercher sur le disque ─────────── T3 : une sonde sur mesure
```

T1 et T2 couvrent presque tous les cas. Ne passez à T3 que si une ligne ne
suffit vraiment pas.

## 2. T1 et T2 : une ligne du catalogue `SOURCES`

Le catalogue se trouve dans `mister-clean.sh`, section « Catalogue des
sources à emplacement connu ». Une ligne = une source, avec 10 colonnes
séparées par `|`. Les espaces autour des `|` sont ignorés. Une ligne qui
commence par `#` est un commentaire.

| # | Colonne | Valeurs |
|---|---|---|
| 1 | section | où la source est sondée : `logs`, `dev`, `pkg`, `agents`, `models`, `big`, `appdata` |
| 2 | cat | catégorie ; son libellé est la clé de message `cat.<cat>` |
| 3 | lieu | `~/chemin` (joker `*` permis), `{syslogs}`, ou `$ commande` (l'outil donne l'emplacement) |
| 4 | outil | outil requis, sinon la ligne est ignorée ; `-` si aucun |
| 5 | seuil | clé de `SIZE_MIN` : `cache` (10 Mio), `bulky` (50 Mio), `appdata` (100 Mio) ; la taille doit être **au moins** égale au seuil |
| 6 | verdict | `safe`, `caution`, `manual`, ou une règle : `age`, `age!App=clé`, `model`, `git` |
| 7 | raison | clé de message ; `-` pour `age` et `git` ; clé du message « ancien » pour `model` |
| 8 | action | mots de l'action (voir plus bas), ou `none` |
| 9 | libellé | `@clé args…` (message du catalogue) ou texte littéral |
| 10 | taille | `du` (taille du dossier) ou nom d'une fonction `TAILLE CHEMIN` → KiB |

Les colonnes 8 (action) et 9 (libellé) acceptent des **jetons** :

| Jeton | Remplacé par |
|---|---|
| `{path}` | chemin complet |
| `{tpath}` | chemin abrégé en `~` |
| `{name}` | dernier élément du chemin |
| `{days}` | valeur de `--days` |

### Le joker (T2)

Avec un `*` dans le lieu, chaque **dossier** qui correspond devient un
candidat. Exemple : `~/.cache/huggingface/hub/*` donne un candidat par
modèle, `~/Library/Developer/Xcode/*DeviceSupport` un candidat par
plateforme.

### Les règles de verdict

Elles sont appliquées par `source_verdict` et documentées en tête du
catalogue.

| Règle | Comportement | Pour quoi |
|---|---|---|
| `age` | safe si rien n'a bougé depuis `--days` jours, caution sinon | caches régénérables |
| `age!App=clé` | idem, mais caution avec la raison `MSG[clé]` si l'app tourne. Plusieurs noms : `age!T3 Code,T3 Code (Beta)=clé` (nom exact du processus) | caches d'une app qui les utilise pendant qu'elle tourne |
| `model` | règle unique des modèles IA : récent → manual, au moins `--model-days` → caution, jamais safe. Avec un joker, le scan de `~/.cache` ignore la racine | modèles, jeux de données retéléchargeables |
| `git` | caution seulement pour un worktree lié, propre, poussé, non modifié depuis `--days` jours ; manual sinon, avec la raison précise ; jamais safe. Outil requis : `git` | worktrees d'agents de code |

**Ajouter une règle** : ajouter une branche dans `source_verdict`, puis la
documenter en tête du catalogue et dans ce tableau.

### Les actions

| Action | Effet |
|---|---|
| `none` | rien (candidat MANUEL) |
| `rm-contents {path}` | vider le dossier |
| `rm-path {path}` | supprimer le chemin |
| `rm-old-files {path} {days}` | supprimer les fichiers de plus de N jours (à combiner avec la taille `old_files_kb`) |
| `cmd OUTIL ARGS…` | lancer l'outil, sans passer par le shell (`cmd brew cleanup --prune=all -s`) |
| `sudo OUTIL ARGS…` | la même chose avec sudo ; à éviter dans une nouvelle source |

Préférez la commande de nettoyage de l'outil (`cmd npm cache clean --force`,
`cmd git -C {path} worktree remove {path}`) à un `rm`, quand elle existe :
l'outil sait mieux que nous ce qui peut partir.

### Choisir un verdict

- **safe** : seulement ce qui se régénère seul et sans perte (cache, vieux
  journaux) **et** que l'app ne lit pas en ce moment. Dans le doute, utilisez
  `age` ou `age!App=…`.
- **caution** : récupérable mais coûteux (retéléchargement, recompilation,
  corbeille), ou risqué si l'utilisateur ne regarde pas.
- **manual** : ce que l'utilisateur doit trier lui-même (sauvegardes,
  données d'app gérées depuis l'app, outils réinstallés par l'app).
- **Ne listez jamais** l'état d'une app (bases `*.db`, `*.sqlite`, profils,
  réglages), ni des identifiants (`~/.orca`, `token`…). N'écrivez pas de
  ligne pour ces chemins, même en manual, et vérifiez qu'aucun joker ne les
  attrape.
- Un dossier qui peut contenir du **travail non sauvegardé** (worktree,
  brouillons) n'est jamais safe : utilisez `git`, ou manual.

## 3. T3 : une sonde sur mesure

Une sonde est une fonction `probe_<nom>`, inscrite dans `PROBES` (section
« Sondes enregistrées » du script) sous la forme `section:probe_<nom>`.
`run_section SECTION` lance, dans l'ordre de `PROBES`, les lignes du
catalogue de la section (entrée réservée `catalogue`, placée en premier si
elle n'est pas citée) et ses sondes. L'ordre compte : c'est celui des
candidats dans le plan.

**Contrat d'une sonde** (rappelé au-dessus de `PROBES`) :

- elle ne propose ses candidats que par `add_candidate` ou `add_model` ;
- ses actions sont construites par `new_action` ;
- elle ne supprime rien et ne lance aucune commande qui modifie le disque ;
- elle n'affiche que par `h2` / `info` (et des listes indentées
  informatives) ;
- si l'outil dont elle dépend est absent, elle ne fait rien et rend 0 ;
- ses variables sont locales.

Exemple réel, en abrégé (`probe_ollama`) :

```zsh
probe_ollama() {
  local LOADED name id sz unit n u rest kb days loaded
  have ollama || return 0
  h2 "$(m ollama.title)"
  LOADED=$(ollama ps 2>/dev/null | awk 'NR>1 {print $1}' | tr '\n' ' ')
  ollama list 2>/dev/null | awk 'NR>1' | while read -r name id sz unit n u rest; do
    # … taille et âge tirés de la sortie d'ollama …
    add_model model_ollama "$name" "ollama:$name" "$kb" "$days" "$loaded" \
      "$(m model.ollama_old.reason "$days" "$MODEL_DAYS" "$name")" "$(new_action cmd ollama rm "$name")"
  done
}
```

Signatures utiles :

- `add_candidate CAT LIBELLÉ CHEMIN KB ÂGE VERDICT RAISON ACTION`
- `add_model CAT LIBELLÉ CHEMIN KB ÂGE CHARGÉ RAISON_SI_ANCIEN ACTION`
- `verdict_for CHEMIN JOURS [RAISON_FORCÉE]` → `VERDICT|raison`, selon l'âge
- `git_verdict CHEMIN JOURS` → `VERDICT|raison` pour un worktree
- `du_kb`, `newest_age_days`, `is_recent`, `have`, `is_running`

## 4. Les messages, en français **et** en anglais

Chaque clé citée par la brique doit exister dans `messages_fr` **et** dans
`messages_en` :

- `cat.<cat>` ;
- la raison (colonne 7) ;
- la clé du libellé `@…` ;
- la clé de `age!App=clé` ;
- les titres `h2` d'une sonde.

Ce sont des formats `printf` : `%s` pour chaque argument passé. Rangez les
clés près de celles du même thème, dans le même ordre dans les deux langues.

Une clé manquante ne fait pas planter le script (`m` affiche `[clé]`), mais
la suite de tests échoue et nomme la clé et la langue
(`tests/test_messages.zsh`, `test_le_catalogue_est_bien_forme`).

## 5. Un test

Les tests tournent dans un bac à sable : un `HOME` jetable, et un `PATH`
réduit aux outils autorisés et aux outils simulés (voir le README, section
Tests). Ajoutez une fonction `test_…` dans un fichier `tests/test_*.zsh`
(nouveau fichier, ou celui du thème).

Pour une source hypothétique déclarée ainsi (clés `cat.mon_outil`,
`mon_outil.label` et `mon_outil.open.reason` ajoutées dans les deux langues) :

```
pkg | mon_outil | ~/.mon-outil/cache | - | cache | age!mon-outil=mon_outil.open.reason | - | rm-contents {path} | @mon_outil.label | du
```

le test ressemble à ceci :

```zsh
# _sonde SECTION : « catégorie|libellé|verdict|raison|action » par candidat.
_sonde() {
  in_sandbox 'CACHE_DAYS=30; MODEL_DAYS=90; probe_sources '"$1"' >/dev/null
    for (( i = 1; i <= ${#CAND_PATH}; i++ )); do
      print -r -- "${CAND_CAT[i]}|${CAND_LABEL[i]}|${CAND_VERDICT[i]}|${CAND_REASON[i]}|$(describe_action "${CAND_ACTION[i]}")"
    done'
  assert_status 0
}

test_brique_mon_outil() {
  make_file "$H/.mon-outil/cache/blob" 12288 200      # 12 Mio, vieux de 200 jours
  age_path "$H/.mon-outil/cache" 200                  # le dossier aussi
  make_file "$H/.mon-outil/etat.sqlite" 60000 200     # ne doit jamais apparaître
  _sonde pkg
  assert_contains "$OUT" "mon_outil|cache de mon outil|safe|"
  assert_not_contains "$OUT" "sqlite"
  print "mon-outil" > "$MC_SANDBOX/running"           # l'app « tourne »
  _sonde pkg
  assert_contains "$OUT" "|caution|"
}
```

Outils du harnais (`tests/lib.zsh`) :

- `make_file CHEMIN KIB [JOURS]` et `age_path CHEMIN JOURS` fabriquent le
  `HOME` ;
- `in_sandbox 'code'` charge le script et lance du code ;
  `run_script --dry-run --skip-spotlight` lance tout le script ;
- `fake_tool NOM 'corps'` simule un outil (`brew`, `ollama`…), et
  `argv_of NOM` donne ses appels ;
- `$MC_SANDBOX/running` liste les apps que `pgrep` dit lancées ;
  `$MC_SANDBOX/open_files` liste les fichiers ouverts (pour `lsof`) ;
- `assert_contains`, `assert_not_contains`, `assert_exists`,
  `assert_not_exists`, `section 'A. SÛR'`, `fail`.

Pour un worktree, créez un vrai dépôt avec `git`, isolé de votre
configuration (voir `_g` et `_depots` dans `tests/test_git.zsh`).

Enfin, mettez à jour le nombre d'entrées attendu dans
`test_le_catalogue_est_bien_forme` (`tests/test_catalogue.zsh`), puis lancez
`./tests/run.zsh`.

## 6. Liste de contrôle

- [ ] la ligne (ou la sonde inscrite dans `PROBES`) ;
- [ ] les clés de messages en **fr** et en **en** ;
- [ ] aucun état d'app ni identifiant ne peut entrer dans le plan ;
- [ ] un test (`tests/test_*.zsh`) et le compte d'entrées mis à jour ;
- [ ] `./tests/run.zsh` passe ;
- [ ] si possible, `./mister-clean.sh --dry-run --fast --skip-spotlight` sur
  une vraie machine qui a l'outil ; sinon, dites-le dans le commentaire de la
  brique (voir Orca).

## Exemples dans le catalogue

- **T3 Code** (section `agents`) : T1 pour les journaux (`safe` +
  `rm-old-files` + `old_files_kb`), pour les caches
  (`age!T3 Code,T3 Code (Beta)=…`) et pour les outils (`manual`) ; T2 `git`
  pour `~/.t3/worktrees/*/*`. La base `statev2.sqlite` n'a pas de ligne.
- **Hugging Face** (section `models`) : T2 `model` pour `hub/*` et
  `datasets/*`, T1 `age` pour le cache `xet`.
- **Orca** (section `agents`) : brique écrite d'après le code source d'Orca
  et **non vérifiée sur une vraie installation**. Son commentaire le dit et
  cite le commit. Elle montre aussi comment exclure les bases, les profils et
  `~/.orca`.
- **Ollama, Docker, snapshots Time Machine, dépendances de projets
  inactifs** : sondes T3 (`probe_ollama`, `probe_docker`, `probe_snapshots`,
  `probe_inactive_deps`).

## Prochaines briques possibles

- **Claude Code** : `~/.claude/projects` (transcriptions de sessions),
  journaux et caches ; attention, `~/.claude` contient aussi des réglages et
  des mémoires à ne jamais lister.
- **Cursor, Conductor, Codex** et autres apps d'agents : journaux, caches,
  worktrees (règle `git`).
- **Sonde générique de worktrees orphelins** : repérer sous `~` les dossiers
  dont `.git` est un fichier qui pointe vers un dépôt disparu.
- **Orca, dossiers configurés** : lire `workspaceDir` et `worktreeBasePath`
  dans les réglages d'Orca pour suivre les worktrees rangés ailleurs que dans
  `~/orca/workspaces`.
