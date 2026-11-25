# needrestart-ntfy

Relance automatique des services par needrestart et notifications
[ntfy](https://ntfy.sh/) de ce qui a été relancé ou reste à faire, pour
Debian Trixie.

## Présentation

- needrestart relance automatiquement les services touchés par une mise à
  jour de bibliothèque, y compris quand il est appelé par unattended-upgrades.
- À chaque passage de dpkg qui a relancé quelque chose, une notification liste
  les services relancés, ceux qui restent à relancer à la main et les paquets
  traités.
- Chaque matin à 07:37, une notification est envoyée si un noyau ou un
  microcode attend un redémarrage, ou si des services restent à relancer.
  Sans rien à signaler, aucune notification n'est envoyée.

## Arborescence de l'archive

```text
needrestart-ntfy-0.4.0/
├── install.sh                 installeur (le seul fichier à lancer)
├── README.md
├── CHANGELOG.md
└── files/                     fichiers à installer
    ├── SHA256SUMS             vérifié automatiquement par install.sh
    ├── etc/
    │   ├── ntfy-send.conf     modèle, installé en 0600
    │   ├── apt/apt.conf.d/98needrestart-ntfy
    │   ├── apt/apt.conf.d/99zz-needrestart-ntfy
    │   └── needrestart/conf.d/50-autorestart.conf
    └── usr/local/sbin/
        ├── ntfy-send.sh
        ├── needrestart-ntfy.sh
        └── needrestart-ntfy-apt.sh
```

Sous `files/`, le chemin d'un fichier est exactement celui où il est
installé : `files/usr/local/sbin/ntfy-send.sh` devient
`/usr/local/sbin/ntfy-send.sh`. L'installeur ajoute aussi une ligne dans
`/etc/crontab`.

Tous les composants portent la même version : `install.sh -v` et l'option
`-v` de chaque script installé affichent `0.4.0`.

## Prérequis

```sh
apt install needrestart curl cron
```

`iconv`, `logger`, `awk`, `sha256sum`, `tar` et les autres commandes
utilisées sont présentes sur une Debian standard. L'installeur vérifie leur
présence, ainsi que l'intégrité de `files/`, avant toute modification.

## Installation

Contrôlez d'abord l'empreinte de l'archive avec la valeur fournie à côté :

```sh
sha256sum needrestart-ntfy-0.4.0.tar.gz
tar xzf needrestart-ntfy-0.4.0.tar.gz
cd needrestart-ntfy-0.4.0
./install.sh -c          # état de la machine (--check), ne modifie rien
./install.sh -n          # simulation (--dry-run)
./install.sh -t          # installation, avec une notification de test à la fin
```

### Topic ntfy

Le topic fait office de mot de passe : quiconque le connaît lit vos
notifications (noms de machines, services, versions de paquets) et peut en
envoyer de fausses. Évitez un nom devinable.

L'installeur choisit, dans cet ordre :

- **D'abord** : si `/etc/ntfy-send.conf` existe déjà, il est conservé tel
  quel.
- **Ensuite** : avec l'option `-f fichier` (`--ntfy-conf fichier`), ce
  fichier est copié en `/etc/ntfy-send.conf` (0600).
- **Ensuite** : si `~` contient une archive de configuration laissée par
  `-p` (voir "Désinstallation"), la plus récente est proposée :
  `Restaurer la configuration archivée (...) ? [O/n]`, Entrée vaut oui. Hors
  terminal, elle est restaurée et l'installeur l'annonce. Seuls les fichiers
  absents sont recréés : `/etc/ntfy-send.conf` (0600) et
  `/etc/needrestart/conf.d/50-autorestart.conf` (0644). Une archive qui
  contient d'autres fichiers est ignorée, avec un avertissement ; un lien
  symbolique n'est jamais restauré.
- **Ensuite** : si l'installeur tourne dans un terminal, le topic est demandé,
  saisi en clair, puis affiché en entier pour confirmation (`[o/N]`). Une
  entrée vide génère `needrestart-` suivi de 24 caractères aléatoires :
  notez-le pour abonner votre téléphone dans l'appli ntfy. Trois essais au
  plus.
- **Sinon** (pas de terminal, ou aucun topic confirmé) : le modèle est
  installé avec `NTFY_TOPIC` vide. Renseignez-le ; la vérification finale
  échoue tant qu'il est vide.

Le serveur reste `https://ntfy.sh` ; pour un autre serveur ou un jeton
d'accès, éditez `/etc/ntfy-send.conf` ou passez par `-f`. Le topic n'est
jamais accepté en argument, pour ne pas apparaître dans `ps` ni dans
l'historique du shell.

### Options

Chaque option a une forme courte et une forme longue, sauf `--no-archive`
(forme longue seulement). Aucune n'est en majuscule. Les options courtes se
combinent (`-pn`) ; `--ntfy-conf` accepte `--ntfy-conf fichier` comme
`--ntfy-conf=fichier`.

Actions, une seule à la fois (sans action : installation) :

- `-u`, `--upgrade` : mise à jour (voir plus bas).
- `-c`, `--check` : état, inventaire seul.
- `-p`, `--purge` : désinstallation complète (voir plus bas).

Options :

- `-f fichier`, `--ntfy-conf fichier` : copie ce fichier en
  `/etc/ntfy-send.conf`, s'il n'existe pas déjà (par exemple la configuration
  d'un autre serveur).
- `-l`, `--logind` : active le relancement automatique de `systemd-logind`
  (serveur sans X, après un essai manuel).
- `-t`, `--test` : envoie une vraie notification de test à la fin.
- `-n`, `--dry-run` : simulation, affiche les actions sans rien modifier.
- `-a`, `--archive` : avec `-p`, archive la configuration sans le demander.
- `--no-archive` : avec `-p`, n'archive pas la configuration.
- `-y`, `--yes` : avec `-p`, ne pose aucune question.
- `-h`, `--help` : aide.
- `-v`, `--version` : version.

### Vérifications finales

Après une installation ou une mise à jour, `install.sh` contrôle :

- que les trois scripts répondent à `-v` ;
- l'ordre des hooks APT : `mark` en `DPkg::Pre-Invoke`, puis `before`,
  `apt-pinvoke` et `after` en `DPkg::Post-Invoke` ;
- que needrestart charge `/etc/needrestart/conf.d/50-autorestart.conf`
  (contrôle en mode liste, qui ne relance rien) ;
- que `/etc/ntfy-send.conf` est valide (simulation d'envoi) ;
- que l'inventaire est standard : trois hooks, une seule ligne cron, deux
  scripts ;
- avec `-t`, l'envoi réel d'une notification.

## Scripts installés

Les trois scripts suivent les conventions d'`install.sh` : une forme courte
et une forme longue par option, aucune option en majuscule. `-V` est refusé
avec un rappel de `-v` (code 2).

`ntfy-send.sh [options] [message...]`, ou `commande | ntfy-send.sh [options]`,
envoie une notification ; d'autres tâches peuvent l'utiliser :

- `-c`, `--conf FICHIER` : fichier de configuration (défaut :
  `/etc/ntfy-send.conf`) ;
- `-t`, `--title TITRE` : titre, préfixé par `[nom de la machine]` ;
- `-p`, `--priority PRIORITÉ` : `1` à `5`, ou `min`, `low`, `default`,
  `high`, `max`, `urgent` ;
- `-g`, `--tags TAGS` : tags ntfy séparés par des virgules ;
- `-n`, `--dry-run` : affiche la requête sans l'envoyer ;
- `-h`, `--help` et `-v`, `--version`.

Les formes longues acceptent `--option valeur` comme `--option=valeur`. Le
premier argument qui n'est pas une option commence le message : les suivants
en font partie, même s'ils commencent par `-`. Pour un message qui commence
par `-`, placez `--` devant. Sans message, ou avec `-`, le message est lu
sur l'entrée standard. Codes de sortie : 0 envoi accepté, 1 échec de
l'envoi, 2 erreur d'usage ou de configuration.

```sh
ntfy-send.sh -t "sauvegarde" -p high -g warning "échec de la sauvegarde"
```

`needrestart-ntfy.sh [options]`, lancé chaque matin par cron :

- `-s`, `--sessions` : signale aussi les sessions utilisateur obsolètes ;
- `-f`, `--force` : notifie même sans rien à signaler (test de la chaîne) ;
- `-n`, `--dry-run` : affiche la notification sans l'envoyer ;
- `-h`, `--help` et `-v`, `--version`.

`needrestart-ntfy-apt.sh mark|before|after` est appelé par les hooks APT ;
à la main, seuls `-h` (`--help`) et `-v` (`--version`) servent.

## Machine déjà équipée

### Ce qui compte comme une installation existante

Avant toute action, `install.sh` dresse un inventaire en lecture seule. Ces
traces bloquent une nouvelle installation :

- un hook APT qui appelle `needrestart-ntfy-apt.sh`, quel que soit le fichier
  (`apt-config dump` montre aussi ceux définis hors de `/etc/apt/apt.conf.d`) ;
- une tâche planifiée qui appelle `needrestart-ntfy.sh` ou
  `needrestart-ntfy-apt.sh` : `/etc/crontab`, `/etc/cron.d/*`, répertoires
  `/etc/cron.hourly` à `/etc/cron.yearly`, crontabs des comptes
  (`/var/spool/cron/crontabs/*`), unités de `/etc/systemd/system` ;
- le script `needrestart-ntfy.sh` ou `needrestart-ntfy-apt.sh` dans
  `/usr/local/sbin`, `/usr/local/bin`, `/usr/sbin`, `/usr/bin`, `/sbin`,
  `/bin`, `/root/bin`, un répertoire du PATH ou un chemin cité par un
  déclencheur, même si rien ne l'appelle.

Les lignes commentées ne comptent pas. Les scripts trouvés ne sont jamais
exécutés : leur version est lue dans le fichier.

Ne bloquent pas, et sont seulement affichés : `ntfy-send.sh` (outil
générique), `/etc/ntfy-send.conf`, les fichiers de
`/etc/needrestart/conf.d`, les sauvegardes, les archives de configuration de
`~`. Si plusieurs fichiers de `conf.d` fixent `$nrconf{restart}`, un
avertissement le signale : needrestart les charge dans l'ordre alphabétique
et le dernier l'emporte.

### Emplacements standard

Une trace est standard si elle se trouve là où l'installeur l'écrit :

- `/usr/local/sbin/needrestart-ntfy.sh` et
  `/usr/local/sbin/needrestart-ntfy-apt.sh` ;
- `mark` et `before` dans `/etc/apt/apt.conf.d/98needrestart-ntfy`, `after`
  dans `/etc/apt/apt.conf.d/99zz-needrestart-ntfy`, chacun une seule fois ;
- une seule ligne active dans `/etc/crontab` qui appelle
  `/usr/local/sbin/needrestart-ntfy.sh`, quel que soit son commentaire.

Toute autre trace est marquée `AUTRE` dans l'inventaire : autre répertoire,
autre fichier, doublon.

### Comportement selon le mode

- `./install.sh` : sans trace, installe. Avec une trace, affiche l'inventaire,
  ne modifie rien et sort avec le code 3.
- `./install.sh -c` : affiche l'inventaire ; code 0 sans trace, 3 sinon.
- `./install.sh -u` : met à jour si toutes les traces sont standard (ou
  installe s'il n'y en a aucune). Refuse avec le code 3 si une seule trace
  est marquée `AUTRE`, et affiche les commandes pour la retirer.
- `-n` fonctionne avec tous les modes : l'inventaire est dressé, les actions
  sont seulement affichées.

### Détail de la mise à jour (`-u`)

- Script plus ancien : sauvegardé puis remplacé, versions avant et après
  affichées.
- Script identique : laissé tel quel.
- Script de même version mais modifié localement, ou de version plus
  récente : conservé, avec un avertissement.
- Hook APT au contenu différent : sauvegardé puis remplacé.
- `/etc/ntfy-send.conf`, `50-autorestart.conf` et la ligne cron : jamais
  modifiés s'ils existent ; recréés s'ils manquent (pour la configuration
  ntfy, dans l'ordre décrit sous "Topic ntfy").
- Rien à changer : "Rien à faire : l'installation est déjà en version 0.4.0".

Les fichiers remplacés sont copiés dans
`/var/backups/needrestart-ntfy/AAAAMMJJ-HHMMSS/`, à leur chemin d'origine.

Pour redéployer la même version, par exemple après une modification locale
d'un script, `-u` ne suffit pas : désinstallez avec `-p`, puis réinstallez.

## Désinstallation

```sh
./install.sh -pn         # simulation (--purge --dry-run)
./install.sh -p          # désinstallation, après confirmation (--purge)
./install.sh -c          # contrôle : "aucune trace", code 0
```

`-p` se comporte comme `apt purge` : il supprime tout ce que l'installeur
connaît, configuration comprise. Il affiche l'inventaire et la liste
"Seront supprimés :", puis pose deux questions :

1. `Désinstaller needrestart-ntfy (9 élément(s)) ? [o/N]` : toute autre
   réponse que `o` ou `oui` abandonne sans rien modifier (code 4). Cette
   réponse décide de la suite.
1. `Archiver la configuration avant suppression ? [O/n]` : Entrée vaut oui ;
   `n` ou `non` supprime sans archiver.

Options, réservées à `-p` :

- `-a`, `--archive` : archive sans poser la seconde question ;
- `--no-archive` : n'archive pas, sans poser la seconde question ;
  incompatible avec `-a` ;
- `-y`, `--yes` : ne pose aucune question ; la configuration est archivée,
  sauf avec `--no-archive`. Hors terminal, `-y` est obligatoire : sans lui,
  `-p` ne supprime rien (code 2).

```sh
./install.sh -p -y                # sans question, avec archive
./install.sh -p -y --no-archive   # sans question ni archive
```

### Archive de la configuration

L'archive est créée dans `~` (`$HOME`, soit `/root` pour root), avec la date
dans son nom, en 0600 car elle contient le topic :

```text
~/needrestart-ntfy-config-AAAAMMJJ-HHMMSS.tar.gz
```

Elle contient `/etc/ntfy-send.conf` et
`/etc/needrestart/conf.d/50-autorestart.conf`, s'ils existent. Elle est
relue avant la moindre suppression : si elle ne peut pas être créée, `-p`
s'arrête sans rien supprimer (code 2). La prochaine installation propose de
la restaurer (voir "Topic ntfy").

Pour reprendre un seul fichier de l'archive, en écrasant celui en place :

```sh
tar -xzf ~/needrestart-ntfy-config-AAAAMMJJ-HHMMSS.tar.gz -C / \
    etc/needrestart/conf.d/50-autorestart.conf
```

`-p` ne supprime jamais ces archives. Pour effacer celles devenues
inutiles :

```sh
rm -f ~/needrestart-ntfy-config-*.tar.gz
```

### Ce qui est supprimé

Uniquement ce que l'installeur connaît, à ses emplacements, versions
précédentes comprises :

- les hooks `98needrestart-ntfy` et `99zz-needrestart-ntfy`, s'ils appellent
  bien `needrestart-ntfy-apt.sh` (sinon : avertissement, fichier conservé) ;
- `/usr/local/sbin/needrestart-ntfy.sh` et
  `/usr/local/sbin/needrestart-ntfy-apt.sh` ;
- dans `/etc/crontab`, les lignes actives qui appellent
  `/usr/local/sbin/needrestart-ntfy.sh` et le commentaire posé par
  l'installeur ;
- `/usr/local/sbin/ntfy-send.sh` et `/etc/ntfy-send.conf`, sauf s'ils servent
  encore (voir plus bas) ;
- `/etc/needrestart/conf.d/50-autorestart.conf` ;
- `/var/backups/needrestart-ntfy/` (sauvegardes des mises à jour) et
  `/etc/crontab.needrestart-ntfy.bak`, laissé par la 0.1.0 ;
- l'état temporaire `/run/needrestart-ntfy`.

Aucune autre copie n'est faite : l'archive de `~` est la seule sauvegarde.
Sans `50-autorestart.conf`, needrestart revient à son mode par défaut : il
demande avant de relancer, et se contente de lister sous unattended-upgrades.

### Ce qui est conservé

- `ntfy-send.sh` et `/etc/ntfy-send.conf`, si une autre tâche appelle
  `ntfy-send.sh` : tâche planifiée (`/etc/crontab`, `/etc/cron.d`,
  `/etc/cron.hourly` à `/etc/cron.yearly`, crontabs des comptes), unité de
  `/etc/systemd/system`, script de `/usr/local/sbin`, `/usr/local/bin` ou
  `/root/bin`. Le premier appel trouvé est affiché :
  `Conservés : ... (utilisés par fichier:ligne)`. Pour les retirer aussi,
  supprimez cet appel, puis relancez `./install.sh -p`.
- les traces non standard (voir ci-dessous) ;
- les archives de configuration de `~` ;
- le répertoire de l'archive extraite (`needrestart-ntfy-0.4.0/`) ;
- un commentaire écrit à la main au-dessus de la ligne cron (par exemple
  `# needrestart`) : seul le commentaire de l'installeur est retiré ;
- les autres fichiers de `/etc/needrestart/conf.d`.

### Traces non standard

`-p` ne supprime jamais un fichier qu'il n'a pas posé. Pour chaque trace
marquée `AUTRE`, il affiche la commande à lancer, et sort avec le code 3 tant
qu'il en reste :

- script ailleurs : `rm -f /chemin/du/script` ;
- ligne dans un fichier (`/etc/cron.d`, hook APT, script de run-parts) :
  `vi +LIGNE fichier` ;
- crontab d'un compte : `crontab -u compte -e` (ligne indiquée) ;
- unité systemd : `systemctl disable --now unité` (et son timer éventuel),
  puis `rm -f fichier ; systemctl daemon-reload` ;
- hook défini hors de `/etc/apt` : `apt-config dump | grep needrestart-ntfy-apt`
  pour le retrouver.

Relancez ensuite `./install.sh -c` : il doit répondre "aucune trace".

## Fonctionnement et limites

- Les hooks APT encadrent celui de needrestart (`99needrestart`) : le relevé
  `before` est pris juste avant needrestart, le relevé `after` juste après. La
  différence donne les services relancés.
- unattended-upgrades installe par défaut en plusieurs passages de dpkg
  (`MinimalSteps`) : une même mise à jour peut produire plusieurs
  notifications.
- Les services exclus par `override_rc` dans `needrestart.conf` (dbus,
  `unattended-upgrades.service`, etc.) ne sont jamais relancés
  automatiquement : ils apparaissent dans "Restent à relancer" et dans le
  rapport quotidien jusqu'à leur relance manuelle ou au prochain redémarrage.
- L'état noyau "inconnu" (fréquent dans les conteneurs) n'est pas signalé,
  pour éviter une alerte quotidienne permanente.
- Les sessions utilisateur obsolètes (shells, screen) sont ignorées ;
  `needrestart-ntfy.sh -s` les inclut.
- `ntfy-send.sh` transmet le topic à curl par un fichier temporaire plutôt que
  sur la ligne de commande ; `/etc/ntfy-send.conf` doit rester en 0600.
- Inventaire : un script renommé n'est pas reconnu. Tout fichier qui contient
  un appel compte, y compris une copie de sauvegarde que cron ou apt
  n'exécuteraient pas : supprimez-la. Un appel placé dans un commentaire
  `/* ... */` d'un fichier APT est compté comme actif.
- La restauration n'est proposée que si `/etc/ntfy-send.conf` manque, et sans
  `-f`. Si `-p` l'a conservé (`ntfy-send.sh` utilisé ailleurs),
  `50-autorestart.conf` est réinstallé depuis le modèle : reprenez le vôtre
  dans l'archive (voir "Archive de la configuration").

## Migration depuis la 0.3.0

Changements visibles :

- `-p` supprime désormais aussi `ntfy-send.sh`, la configuration et les
  sauvegardes, après la question d'archivage (voir "Désinstallation").
- Les trois scripts prennent `-v` (`--version`) au lieu de `-V`, refusé avec
  un rappel (code 2) : adaptez vos propres scripts qui appelleraient
  `ntfy-send.sh -V`. Les autres options courtes ne changent pas.
- Les trois scripts acceptent les formes longues (voir "Scripts installés").

Les hooks APT, la ligne cron et les modèles de configuration ne changent pas.

Sur une machine installée en 0.3.0, avec l'installeur de la 0.4.0 :

```sh
./install.sh -c          # attendu : "installation standard", code 3
./install.sh -u          # mise à jour vers la 0.4.0 (scripts remplacés)
```

Ou, pour repartir de zéro :

```sh
./install.sh -p          # o, puis Entrée pour archiver la configuration
./install.sh             # propose de restaurer l'archive
```

Sans archive (`n` à la seconde question, ou `--no-archive`), la
réinstallation redemande le topic.

Supprimez ensuite le répertoire `needrestart-ntfy-0.3.0` resté sur le
serveur : son `-p` est celui de la 0.3.0, qui conserve la configuration.

### Depuis la 0.2.0

La 0.3.0 a renommé les options d'`install.sh` : `-U` devient `-u` (mise à
jour), `-u` devient `-p` (désinstallation), `-s` devient `-c` (état),
`-c fichier` devient `-f fichier`, `-T` devient `-t`, `-V` devient `-v`. Les
anciennes options sont refusées avec un rappel de la nouvelle forme
(code 2). `./install.sh -u` met une installation 0.2.0 directement en 0.4.0.

Supprimez ensuite le répertoire `needrestart-ntfy-0.2.0` : avec son script,
`-u` désinstalle, sans confirmation.

## Codes de sortie

- `0` : succès ; avec `-c`, aucune trace trouvée.
- `1` : au moins une vérification finale a échoué (par exemple topic vide).
- `2` : erreur d'usage, prérequis manquant, lancement hors root, contenu de
  `files/` altéré, `-p` hors terminal sans `-y`, ou archivage impossible
  avant `-p` ; rien n'a été modifié.
- `3` : installation existante détectée, rien n'a été modifié ; avec `-p`,
  des traces non standard subsistent et sont à retirer à la main.
- `4` : désinstallation abandonnée à la confirmation, rien n'a été modifié.
