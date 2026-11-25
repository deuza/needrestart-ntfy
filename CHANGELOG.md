# Changelog

Toutes les évolutions notables de needrestart-ntfy (archive, installeur et
scripts) sont consignées dans ce fichier.

Le format suit [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) et le
projet applique le [versionnage sémantique](https://semver.org/).

## [Unreleased]

## [0.4.0] - 2026-11-25

### Added

- `install.sh -p` : après la confirmation, question
  `Archiver la configuration avant suppression ? [O/n]` (oui par défaut).
  L'archive `~/needrestart-ntfy-config-AAAAMMJJ-HHMMSS.tar.gz`, en 0600,
  contient `/etc/ntfy-send.conf` et `50-autorestart.conf` ; si elle ne peut
  pas être créée, rien n'est supprimé (code 2).
- Options `-a` (`--archive`), qui archive sans le demander, et
  `--no-archive` (forme longue seulement), qui n'archive pas ; réservées à
  `-p` et incompatibles entre elles.
- Installation et mise à jour : sans `-f` et si `/etc/ntfy-send.conf`
  manque, restauration proposée depuis la dernière archive de `~` (`[O/n]`,
  oui par défaut ; hors terminal, restauration annoncée). Seuls les fichiers
  absents sont recréés ; une archive au contenu inattendu est ignorée et un
  lien symbolique n'est jamais restauré.
- `install.sh -p` affiche la liste "Seront supprimés :" avant la
  confirmation.
- Inventaire : les archives de configuration de `~` sont signalées (nombre
  et plus récente), sans bloquer l'installation.
- Formes longues pour les options des trois scripts : `--conf`, `--title`,
  `--priority`, `--tags`, `--dry-run`, `--help` et `--version` pour
  `ntfy-send.sh`, qui accepte aussi `--option=valeur` ; `--sessions`,
  `--force`, `--dry-run`, `--help` et `--version` pour
  `needrestart-ntfy.sh` ; `--help` et `--version` pour
  `needrestart-ntfy-apt.sh`.
- Rappel de la nouvelle forme quand `-V` est passé à l'un des trois scripts
  (code 2).
- Sections "Scripts installés" et "Migration depuis la 0.3.0" dans le
  README.

### Changed

- `install.sh -p` supprime tout ce que l'installeur connaît, comme
  `apt purge` : en plus des hooks, des deux scripts de déclenchement, de la
  ligne cron et de `/run/needrestart-ntfy`, il retire
  `/usr/local/sbin/ntfy-send.sh`, `/etc/ntfy-send.conf`,
  `/etc/needrestart/conf.d/50-autorestart.conf`,
  `/var/backups/needrestart-ntfy/` et `/etc/crontab.needrestart-ntfy.bak`
  (0.1.0). `ntfy-send.sh` et sa configuration restent en place si une tâche
  planifiée, une unité systemd ou un script local appelle `ntfy-send.sh`.
  Les traces non standard, les archives de `~` et le répertoire de l'archive
  extraite ne sont jamais supprimés.
- La confirmation de `-p` compte les éléments à supprimer :
  `(N élément(s))` au lieu de `(N trace(s) standard)`.
- `-y` (`--yes`) avec `-p` archive aussi la configuration, sauf avec
  `--no-archive`.
- Option de version des trois scripts : `-v` (`--version`) au lieu de `-V`,
  comme pour `install.sh` ; la vérification finale d'`install.sh` utilise
  `-v`.
- `install.sh` vérifie aussi la présence de `tar`, nécessaire à l'archive de
  configuration.
- Version 0.4.0 pour l'archive, l'installeur et les trois scripts.

### Removed

- Option `-V` des trois scripts, remplacée par `-v`.
- Sauvegarde dans `/var/backups/needrestart-ntfy/` des fichiers supprimés
  par `-p` : ce répertoire est lui-même supprimé ; l'archive de `~` sauvegarde
  la configuration.
- Section "Tout retirer" du README : `-p` retire désormais ces fichiers
  lui-même.

### Fixed

- `ntfy-send.sh` sous posh : les options placées après le message étaient
  interprétées au lieu de faire partie du message, contrairement à dash et
  bash. Le premier argument qui n'est pas une option commence désormais le
  message sous tous les shells.

## [0.3.0] - 2026-11-25

### Added

- Formes longues pour toutes les options d'`install.sh` : `--upgrade`,
  `--check`, `--purge`, `--ntfy-conf`, `--logind`, `--test`, `--dry-run`,
  `--yes`, `--help` et `--version` ; `--ntfy-conf=fichier` est accepté.
- Confirmation `[o/N]` avant la désinstallation quand `install.sh` tourne dans
  un terminal ; option `-y` (`--yes`) pour la passer, obligatoire hors
  terminal.
- Code de sortie 4 : désinstallation abandonnée à la confirmation, rien n'a
  été modifié.
- Rappel de la nouvelle forme quand une ancienne option de la 0.2.0 est
  utilisée (`-U`, `-s`, `-T`, `-V`, `-c fichier`).
- Section "Migration depuis la 0.2.0" dans le README.

### Changed

- Options d'`install.sh` renommées, sans compatibilité avec la 0.2.0, et plus
  aucune option en majuscule : `-U` devient `-u` (mise à jour), `-u` devient
  `-p` (désinstallation), `-s` devient `-c` (état), `-c fichier` devient
  `-f fichier` (conf ntfy), `-T` devient `-t` (test), `-V` devient `-v`
  (version). Les options des trois scripts ne changent pas.
- Messages d'erreur d'options produits par `install.sh` lui-même, en
  français, au lieu de ceux de `getopts`.
- Version 0.3.0 pour l'archive, l'installeur et les trois scripts ; dans les
  scripts, seules la ligne `VERSION` et l'en-tête changent.

## [0.2.0] - 2026-11-25

### Added

- Inventaire en lecture seule avant toute action : hooks APT (via
  `apt-config dump` et lecture de `/etc/apt`), tâches planifiées
  (`/etc/crontab`, `/etc/cron.d`, `/etc/cron.{hourly,daily,weekly,monthly,yearly}`,
  crontabs des comptes), unités de `/etc/systemd/system`, scripts dans les
  répertoires `bin` et `sbin` habituels, dans le PATH et aux chemins cités par
  les déclencheurs. Les scripts trouvés ne sont jamais exécutés : leur version
  est lue dans le fichier.
- Code de sortie 3 : installation existante détectée, rien n'est modifié.
- Option `-s` : affiche l'inventaire sans rien modifier (code 0 si aucune
  trace, 3 sinon).
- Option `-U` : mise à jour d'une installation aux emplacements standard, avec
  les versions avant et après. Un script modifié localement ou plus récent est
  conservé. Une configuration ou une ligne cron existante n'est jamais
  modifiée ; ce qui manque est recréé.
- Sauvegarde de tout fichier remplacé ou supprimé dans
  `/var/backups/needrestart-ntfy/AAAAMMJJ-HHMMSS/`, chemin d'origine conservé.
- Saisie du topic ntfy quand l'installeur tourne dans un terminal : saisie en
  clair, confirmation du topic complet, trois essais au plus. Une entrée vide
  génère un topic `needrestart-` suivi de 24 caractères aléatoires.
- Contrôle automatique de l'intégrité de l'archive (`files/SHA256SUMS`) avant
  toute installation ou mise à jour.
- Vérification finale de l'inventaire après installation : trois hooks, une
  seule ligne cron, deux scripts, tous aux emplacements standard.
- Commandes de nettoyage affichées pour chaque trace non standard.
- Avertissement si plusieurs fichiers de `conf.d` fixent `$nrconf{restart}`.

### Changed

- Arborescence : seuls `install.sh`, `README.md` et `CHANGELOG.md` restent à la
  racine ; les fichiers à installer sont dans `files/`, rangés selon leur
  chemin de destination.
- Version unique 0.2.0 pour l'archive, l'installeur et les trois scripts.
  Dans les scripts, seules la ligne `VERSION` et l'en-tête changent.
- Un seul CHANGELOG (celui-ci) : il reprend l'historique des trois composants,
  dont les fichiers CHANGELOG séparés disparaissent.
- `-u` conserve désormais `/usr/local/sbin/ntfy-send.sh`, outil générique
  utilisable par d'autres tâches. Il ne retire que les traces aux emplacements
  standard et indique les commandes à lancer pour les autres.
- Sauvegarde de `/etc/crontab` dans `/var/backups/needrestart-ntfy/` au lieu
  de `/etc/crontab.needrestart-ntfy.bak`.
- `SHA256SUMS` déplacé dans `files/`.
- Les options `-c`, `-l` et `-T` sont refusées avec `-s` et `-u` ; `-U`, `-s`
  et `-u` s'excluent mutuellement.

## [0.1.0] - 2026-11-22

Composants livrés : ntfy-send.sh 0.1.0, needrestart-ntfy.sh 0.1.1,
needrestart-ntfy-apt.sh 0.1.1.

### Added

- install.sh : vérification des prérequis avant toute modification,
  installation des scripts, des hooks APT, des fichiers de configuration et de
  la ligne cron, puis vérifications automatiques.
- install.sh : options `-c` (configuration ntfy existante), `-l` (relancement
  de systemd-logind), `-T` (notification de test), `-n` (simulation) et `-u`
  (désinstallation).
- install.sh : installation rejouable, fichiers de configuration jamais
  écrasés, ligne cron jamais dupliquée, sauvegarde de `/etc/crontab` avant
  modification.
- Modèle `50-autorestart.conf` et fichier `SHA256SUMS`.
- ntfy-send.sh 0.1.0 : envoi d'une notification vers un serveur ntfy (ntfy.sh
  ou auto-hébergé), message passé en argument ou lu sur l'entrée standard.
- ntfy-send.sh : options `-t` (titre), `-p` (priorité), `-g` (tags), `-c`
  (fichier de configuration), `-n` (simulation), `-h` et `-V`.
- ntfy-send.sh : titre systématiquement préfixé par le nom de la machine.
- ntfy-send.sh : configuration dans `/etc/ntfy-send.conf`, lue sans être
  exécutée, avec les clés `NTFY_SERVER`, `NTFY_TOPIC` et `NTFY_TOKEN`.
- ntfy-send.sh : nettoyage UTF-8 du message et troncature à 4000 octets sans
  couper un caractère, pour éviter sa conversion en pièce jointe par ntfy.
- ntfy-send.sh : codes de sortie 0 succès, 1 échec d'envoi, 2 erreur d'usage
  ou de configuration ; erreurs journalisées sur la sortie d'erreur et dans
  syslog ; délai maximal d'environ 45 secondes si le serveur ne répond pas.
- needrestart-ntfy.sh 0.1.0 : lecture de `needrestart -b` (mode batch, qui ne
  relance jamais rien) et notification par `ntfy-send.sh` si une action
  manuelle est nécessaire.
- needrestart-ntfy.sh : noyau en attente (états 2 et 3) et microcode obsolète
  signalés en priorité `high`, avec les versions actuelle et attendue.
- needrestart-ntfy.sh : services encore à relancer (exclus par `override_rc`
  ou en échec) et conteneurs signalés en priorité `default`.
- needrestart-ntfy.sh : options `-s` (sessions utilisateur obsolètes, ignorées
  par défaut), `-f` (test de la chaîne de notification) et `-n` (transmise à
  `ntfy-send.sh`).
- needrestart-ntfy.sh : notification dédiée si `needrestart -b` échoue ; codes
  de sortie 0, 1 et 2 ; chemins surchargeables par `NR_BIN` et `NTFY_SEND`.
- needrestart-ntfy-apt.sh 0.1.0 : trois modes appelés par des hooks APT,
  `mark` (avant dpkg), `before` (avant needrestart) et `after` (après
  needrestart), avec les fichiers `98needrestart-ntfy` et
  `99zz-needrestart-ntfy` qui encadrent le hook `99needrestart` de Debian.
- needrestart-ntfy-apt.sh : notification des services et conteneurs relancés
  automatiquement, par différence entre deux relevés `needrestart -b`, avec
  les services restant à relancer à la main et les paquets traités par le
  passage de dpkg (extraits de `/var/log/dpkg.log`).
- needrestart-ntfy-apt.sh : aucune notification si rien n'a été relancé ;
  needrestart n'est interrogé qu'une fois s'il n'y a rien à relancer ; mêmes
  conditions de déclenchement qu'`apt-pinvoke` (drapeaux `unpacked` et
  `errored`, variable `NEEDRESTART_SUSPEND`).
- needrestart-ntfy-apt.sh : ne fait jamais échouer apt (code 0 en mode hook,
  erreurs sur la sortie d'erreur et dans syslog).

### Changed

- needrestart-ntfy.sh 0.1.1 : option `-f` en priorité `default` au lieu de
  `low`, qui passait inaperçue sur le téléphone (ni son ni vibration).
- needrestart-ntfy-apt.sh 0.1.1 : paquet réinstallé dans la même version
  affiché `(réinstallé)` au lieu de `version -> version`.

### Security

- ntfy-send.sh : refus d'un fichier de configuration qui n'appartient pas à
  root ou qui donne des droits au groupe ou aux autres comptes.
- ntfy-send.sh : topic et jeton transmis à curl par un fichier temporaire en
  0600, jamais sur la ligne de commande (invisibles dans `ps` et `/proc`).
- ntfy-send.sh : suppression des caractères de contrôle du titre, ce qui
  empêche l'injection d'en-têtes HTTP.
- ntfy-send.sh : fichier `~/.curlrc` ignoré (`curl -q`) et protocoles limités
  à http et https.
