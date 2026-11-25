#!/bin/sh
# =============================================================================
# install.sh - Installe, met à jour ou désinstalle needrestart-ntfy :
#
#   - relance automatique des services par needrestart (conf.d) ;
#   - ntfy-send.sh, envoi de notifications ntfy ;
#   - needrestart-ntfy.sh, rapport quotidien par cron (noyau, microcode,
#     services exclus du relancement automatique) ;
#   - needrestart-ntfy-apt.sh et ses hooks APT, notification des services
#     relancés à chaque passage de dpkg.
#
# Version : 0.4.0
#
# Usage :
#   ./install.sh [-n] [-l] [-t] [-f fichier]       installation
#   ./install.sh -u [-n] [-l] [-t] [-f fichier]    mise à jour   (--upgrade)
#   ./install.sh -c                                état          (--check)
#   ./install.sh -p [-y] [-a|--no-archive] [-n]    désinstallation (--purge)
#
# -p supprime tout ce que l'installeur connaît, configurations et
# sauvegardes comprises, comme apt purge. Avant suppression, il propose
# d'archiver la configuration dans ~ ; l'installation suivante propose de
# la restaurer.
#
# Toutes les options ont une forme longue (voir --help). Aucune option n'est
# en majuscule, pour qu'on ne puisse pas en confondre deux par la casse.
#
# Avant toute action, le script dresse l'inventaire de ce qui existe déjà
# sur la machine : hooks APT, tâches planifiées, scripts. S'il trouve une
# installation existante, il ne modifie rien et sort avec le code 3 ; -u
# la met à jour si elle se trouve aux emplacements standard.
#
# Codes de sortie :
#   0  succès ; avec -c : aucune trace trouvée
#   1  au moins une vérification finale a échoué
#   2  erreur d'usage, prérequis manquant ou archive altérée : rien n'a été
#      modifié
#   3  installation existante détectée : rien n'a été modifié ; avec -p :
#      des traces non standard subsistent et sont à retirer à la main
#   4  désinstallation abandonnée à la confirmation : rien n'a été modifié
#
# Écrit en shell POSIX : fonctionne sous dash, bash et posh.
# =============================================================================

# Une variable non définie est une erreur ; les codes de retour des
# commandes sont traités explicitement, d'où l'absence de "set -e".
set -u

# Locale C : motifs et tris strictement ASCII, comme needrestart lui-même
# lorsqu'il trie les fichiers de conf.d.
LC_ALL=C
export LC_ALL

# Les fichiers installés reçoivent des droits explicites (install -m) ;
# ce umask protège les fichiers temporaires et les sauvegardes.
umask 077

VERSION='0.4.0'
PROG='install.sh'

# Répertoire de l'archive, pour trouver les fichiers à installer quel que
# soit le répertoire courant.
SRC=$(cd -- "$(dirname -- "$0")" && pwd -P) || exit 2
FILES=$SRC/files

# -----------------------------------------------------------------------------
# Emplacements standard : ceux qu'écrit l'installeur
# -----------------------------------------------------------------------------

BIN_DIR=/usr/local/sbin
APT_DIR=/etc/apt/apt.conf.d
APT_MAIN=/etc/apt/apt.conf
NR_BIN=/usr/sbin/needrestart
NR_CONF_MAIN=/etc/needrestart/needrestart.conf
NR_CONF_DIR=/etc/needrestart/conf.d
NR_CONF=$NR_CONF_DIR/50-autorestart.conf
NTFY_CONF=/etc/ntfy-send.conf
CRONTAB=/etc/crontab
STATE_DIR=/run/needrestart-ntfy
BACKUP_ROOT=/var/backups/needrestart-ntfy

# Sauvegarde de /etc/crontab laissée par la version 0.1.0 de l'installeur.
OLD_CRON_BAK=/etc/crontab.needrestart-ntfy.bak

# Archives de configuration créées par -p : dans le répertoire personnel de
# l'utilisateur (root), horodatées pour ne jamais s'écraser entre elles.
ARCHIVE_DIR=${HOME:-/root}
ARCHIVE_PREFIX=needrestart-ntfy-config-

SCRIPTS='ntfy-send.sh needrestart-ntfy.sh needrestart-ntfy-apt.sh'
TRIGGER_SCRIPTS='needrestart-ntfy.sh needrestart-ntfy-apt.sh'
HOOKS='98needrestart-ntfy 99zz-needrestart-ntfy'

# Ligne cron : après la fenêtre d'apt-daily-upgrade.timer (06:00 + 60 min).
# Le commentaire est identique à celui de la 0.1.0, pour que -p le retire.
CRON_MARK='# needrestart-ntfy : rapport quotidien (installé par install.sh)'
CRON_CMD=$BIN_DIR/needrestart-ntfy.sh
CRON_LINE="37 7 * * *	root	$CRON_CMD"

# Répertoires fouillés à la recherche des scripts, en plus de ceux du PATH
# et de ceux cités par les déclencheurs.
SEARCH_DIRS='/usr/local/sbin /usr/local/bin /usr/sbin /usr/bin /sbin /bin /root/bin'

# Motifs (expressions rationnelles awk, sans barre oblique inverse) des
# appels recherchés.
PAT_APT='needrestart-ntfy-apt[.]sh'
PAT_ANY='needrestart-ntfy(-apt)?[.]sh'

# Topic généré automatiquement : préfixe lisible et suffixe aléatoire.
TOPIC_PREFIX='needrestart-'
TOPIC_RANDOM_LEN=24
TOPIC_TRIES=3

# -----------------------------------------------------------------------------
# État du programme
# -----------------------------------------------------------------------------

MODE=install # install, update, status ou uninstall
DRY_RUN=0
WITH_LOGIND=0
SEND_TEST=0
ASSUME_YES=0
ARCHIVE=0    # -a : archiver la configuration sans le demander
NO_ARCHIVE=0 # --no-archive : ne pas archiver, sans le demander
CONF_SRC=''

# Renseignés pendant l'exécution
NR_RESTORED=0   # 1 si 50-autorestart.conf vient d'être restauré
ARCHIVE_FILE='' # archive créée par -p
NTFY_USER=''    # fichier qui appelle ntfy-send.sh hors needrestart-ntfy

WARNINGS=0
FAILURES=0
CHANGES=0

TMP_DIR=''
BACKUP_DIR=''

# Résultat de detect() : none, standard ou other
STATUS=none
TRACES=0
OTHERS=0

# -----------------------------------------------------------------------------
# Fonctions utilitaires
# -----------------------------------------------------------------------------

say() { printf '%s\n' "$*"; }

warn() {
	printf 'ATTENTION : %s\n' "$*"
	WARNINGS=$((WARNINGS + 1))
}

die() {
	printf '%s: %s\n' "$PROG" "$2" >&2
	exit "$1"
}

# Affiche un compte rendu d'action, sauf en simulation (la ligne
# "[simulation]" en tient lieu).
done_msg() {
	[ "$DRY_RUN" -eq 1 ] || say "$*"
}

# Exécute une commande, ou l'affiche seulement en simulation.
act() {
	if [ "$DRY_RUN" -eq 1 ]; then
		say "[simulation] $*"
	else
		"$@"
	fi
}

# L'appel indirect par "trap cleanup 0" est invisible pour l'analyseur,
# d'où la désactivation de l'avertissement SC2317 (code inaccessible).
# shellcheck disable=SC2317
cleanup() {
	if [ -n "$TMP_DIR" ] && [ -d "$TMP_DIR" ]; then
		rm -rf -- "$TMP_DIR"
	fi
}

usage() {
	cat <<EOF
Usage : $PROG [options]                         installation
        $PROG -u [options]                      mise à jour
        $PROG -c                                état (inventaire seul)
        $PROG -p [-y] [-a|--no-archive] [-n]    désinstallation complète

Actions (une seule à la fois ; sans action : installation) :
  -u, --upgrade            met à jour une installation aux emplacements
                           standard
  -c, --check              affiche l'inventaire sans rien modifier
                           (code 3 si une installation est trouvée, 0 sinon)
  -p, --purge              désinstalle tout ce que l'installeur connaît
                           (scripts, hooks, cron, configurations,
                           sauvegardes), après confirmation, et propose
                           d'archiver la configuration dans ~

Options :
  -f, --ntfy-conf FICHIER  installe ce fichier comme $NTFY_CONF s'il
                           n'existe pas encore (configuration d'un autre
                           serveur) ; forme --ntfy-conf=FICHIER acceptée
  -l, --logind             active le relancement automatique de
                           systemd-logind (serveur sans X, après un essai
                           manuel)
  -t, --test               envoie une vraie notification de test à la fin
  -n, --dry-run            simulation : affiche les actions sans rien modifier
  -a, --archive            avec -p : archive la configuration sans le
                           demander
      --no-archive         avec -p : n'archive pas la configuration
  -y, --yes                avec -p : ne pose aucune question (désinstallation
                           confirmée, configuration archivée sauf avec
                           --no-archive) ; obligatoire hors terminal
  -h, --help               affiche cette aide
  -v, --version            affiche la version

Sans -f, et si $NTFY_CONF n'existe pas : restauration proposée
depuis la dernière archive de $ARCHIVE_DIR
(${ARCHIVE_PREFIX}*.tar.gz), sinon saisie du topic dans un terminal
(entrée vide : topic généré).

Codes de sortie : 0 succès, 1 vérification en échec, 2 erreur d'usage ou
prérequis manquant, 3 installation existante (rien n'est modifié),
4 désinstallation abandonnée (rien n'est modifié).
EOF
}

# Une seule action parmi -u, -c et -p.
set_mode() {
	[ "$MODE" = install ] || die 2 "les options -u, -c et -p s'excluent mutuellement"
	MODE=$1
}

# Option courte inconnue, avec un rappel pour celles de la 0.2.0.
#   $1 : lettre de l'option
unknown_option() {
	case $1 in
	# -f n'arrive ici que sans son argument : getopts renvoie ":" (POSIX) ou
	# "?" (posh) dans ce cas.
	f) die 2 "option -f (--ntfy-conf) : argument manquant (voir $PROG --help)" ;;
	U) hint='depuis la 0.3.0, mise à jour : -u (--upgrade)' ;;
	s) hint='depuis la 0.3.0, état : -c (--check)' ;;
	T) hint='depuis la 0.3.0, notification de test : -t (--test)' ;;
	V) hint='depuis la 0.3.0, version : -v (--version)' ;;
	*) hint="voir $PROG --help" ;;
	esac
	die 2 "option inconnue : -$1 ($hint)"
}

# Version d'un script du projet, lue sans l'exécuter (ligne VERSION='x.y.z').
# Un fichier trouvé sur la machine n'est jamais exécuté par l'installeur.
#   $1 : chemin du script
version_of() {
	sed -n "s/^VERSION='\([0-9][0-9.]*\)'\$/\1/p" "$1" 2>/dev/null | head -n 1
}

# Compare deux versions x.y.z : affiche -1, 0 ou 1.
#   $1 : version a, $2 : version b
ver_cmp() {
	awk -v a="$1" -v b="$2" 'BEGIN {
		na = split(a, x, "."); nb = split(b, y, ".")
		n = (na > nb) ? na : nb
		for (i = 1; i <= n; i++) {
			xi = (i <= na) ? x[i] + 0 : 0
			yi = (i <= nb) ? y[i] + 0 : 0
			if (xi < yi) { print -1; exit }
			if (xi > yi) { print 1; exit }
		}
		print 0
	}'
}

# Chemin réel d'un répertoire (liens symboliques résolus), vide s'il
# n'existe pas.
#   $1 : répertoire
canon_dir() {
	(cd -P -- "$1" 2>/dev/null && pwd -P)
}

# Sauvegarde un fichier avant de le remplacer ou de le supprimer, dans
# /var/backups/needrestart-ntfy/AAAAMMJJ-HHMMSS/ en conservant son chemin.
#   $1 : chemin absolu du fichier
backup_file() {
	[ -e "$1" ] || return 0
	if [ -z "$BACKUP_DIR" ]; then
		BACKUP_DIR=$BACKUP_ROOT/$(date +%Y%m%d-%H%M%S)
	fi
	act mkdir -p "$BACKUP_DIR${1%/*}" &&
		act cp -p "$1" "$BACKUP_DIR$1" &&
		done_msg "sauvegarde : $BACKUP_DIR$1"
}

# Vrai si une ligne active (non commentée) de /etc/crontab appelle le
# script standard.
active_cron_line() {
	grep -v '^[[:space:]]*#' "$CRONTAB" 2>/dev/null | grep -qF "$CRON_CMD"
}

# -----------------------------------------------------------------------------
# Inventaire
# -----------------------------------------------------------------------------

# Ajoute une ligne à l'inventaire.
#   $1 : nature (hook, cron, unit, script, info, warn)
#   $2 : classe (standard, AUTRE, -)
#   $3 : libellé
#   $4 : emplacement (fichier:ligne ou chemin)
#   $5 : chemin du script appelé (facultatif)
record() {
	printf '%s|%s|%s|%s|%s\n' "$1" "$2" "$3" "$4" "${5:-}" >>"$TMP_DIR/inventory"
}

# Liste les appels à un script du projet dans un fichier, lignes de
# commentaire exclues, au format "fichier:ligne|chemin|mot suivant". Le mot
# suivant le chemin est le mode d'un hook APT (mark, before, after).
#   $1 : fichier
#   $2 : caractères qui ouvrent un commentaire en début de ligne
#   $3 : motif du nom de script recherché
scan_calls() {
	awk -v file="$1" -v cc="$2" -v pat="$3" '
		{
			line = $0
			sub(/^[ \t]+/, "", line)
			if (line == "" || index(cc, substr(line, 1, 1)) > 0) next
			if ($0 !~ pat) next
			n = split($0, t, /[^A-Za-z0-9_.\/@~+-]+/)
			path = ""
			word = ""
			for (i = 1; i <= n; i++)
				if (t[i] ~ (pat "$")) {
					path = t[i]
					word = (i < n) ? t[i + 1] : ""
				}
			printf "%s:%d|%s|%s\n", file, NR, path, word
		}' "$1"
}

# Libellé complémentaire quand le script appelé n'existe pas.
#   $1 : chemin cité par le déclencheur
missing_note() {
	case $1 in
	/*) [ -e "$1" ] || printf ' (script absent)' ;;
	'') ;;
	*) printf ' (via le PATH)' ;;
	esac
}

# Hooks APT : apt-config dump montre ce qu'apt exécute réellement, quel que
# soit le fichier ; la lecture des fichiers donne leur emplacement.
detect_apt() {
	: >"$TMP_DIR/apt-hits"
	for f in "$APT_MAIN" "$APT_DIR"/*; do
		[ -f "$f" ] || continue
		scan_calls "$f" '#/' "$PAT_APT" >>"$TMP_DIR/apt-hits"
	done

	seen=' '
	while IFS='|' read -r where path mode; do
		file=${where%:*}
		class=AUTRE
		if [ "$path" = "$BIN_DIR/needrestart-ntfy-apt.sh" ] &&
			[ "${file%/*}" = "$APT_DIR" ]; then
			case "${file##*/}:$mode" in
			98needrestart-ntfy:mark | 98needrestart-ntfy:before | 99zz-needrestart-ntfy:after)
				class=standard
				;;
			*) ;; # autre fichier ou autre mode : non standard
			esac
		fi
		# Un même mode présent deux fois est un doublon.
		if [ "$class" = standard ]; then
			case $seen in
			*" $mode "*) class=AUTRE ;;
			*) seen="$seen$mode " ;;
			esac
		fi
		note=$(missing_note "$path")
		record hook "$class" "hook APT ($mode)$note" "$where" "$path"
	done <"$TMP_DIR/apt-hits"

	hits=$(wc -l <"$TMP_DIR/apt-hits" | tr -d ' ')
	dump=$(apt-config dump 2>/dev/null | grep -c "$PAT_APT")
	if [ "$dump" -gt "$hits" ]; then
		record hook AUTRE "hook APT d'origine inconnue" \
			"apt-config dump ($((dump - hits)) entrée(s))"
	fi
}

# Fichiers de tâches planifiées examinés : cron système, run-parts,
# crontabs des comptes. Un chemin par ligne.
cron_files() {
	for f in "$CRONTAB" /etc/cron.d/* /etc/cron.hourly/* /etc/cron.daily/* \
		/etc/cron.weekly/* /etc/cron.monthly/* /etc/cron.yearly/* \
		/var/spool/cron/crontabs/*; do
		[ ! -f "$f" ] || printf '%s\n' "$f"
	done
}

# Tâches planifiées : cron système, run-parts, crontabs des comptes.
detect_cron() {
	: >"$TMP_DIR/cron-hits"
	cron_files >"$TMP_DIR/cron-files"
	while IFS= read -r f; do
		scan_calls "$f" '#' "$PAT_ANY" >>"$TMP_DIR/cron-hits"
	done <"$TMP_DIR/cron-files"

	std_seen=0
	while IFS='|' read -r where path _word; do
		file=${where%:*}
		class=AUTRE
		if [ "$file" = "$CRONTAB" ] && [ "$path" = "$CRON_CMD" ] &&
			[ "$std_seen" -eq 0 ]; then
			class=standard
			std_seen=1
		fi
		case $file in
		/var/spool/cron/crontabs/*) label="crontab de ${file##*/}" ;;
		*) label='cron' ;;
		esac
		note=$(missing_note "$path")
		record cron "$class" "$label$note" "$where" "$path"
	done <"$TMP_DIR/cron-hits"
}

# Unités systemd locales (l'installeur n'en crée jamais : toujours AUTRE).
# Les liens symboliques (*.wants) sont exclus pour ne pas compter deux fois
# la même unité.
detect_units() {
	: >"$TMP_DIR/unit-hits"
	[ -d /etc/systemd/system ] || return 0
	find /etc/systemd/system -type f 2>/dev/null | sort >"$TMP_DIR/unit-files"
	while IFS= read -r f; do
		scan_calls "$f" '#;' "$PAT_ANY" >>"$TMP_DIR/unit-hits"
	done <"$TMP_DIR/unit-files"

	while IFS='|' read -r where path _word; do
		note=$(missing_note "$path")
		record unit AUTRE "unité systemd$note" "$where" "$path"
	done <"$TMP_DIR/unit-hits"
}

# Scripts : répertoires habituels, répertoires du PATH et répertoires cités
# par les déclencheurs, chacun pris une seule fois sous son chemin réel.
detect_scripts() {
	{
		for d in $SEARCH_DIRS; do
			printf '%s\n' "$d"
		done
		printf '%s\n' "${PATH:-}" | tr ':' '\n'
		cut -d '|' -f 2 "$TMP_DIR/apt-hits" "$TMP_DIR/cron-hits" \
			"$TMP_DIR/unit-hits" | sed -n 's#^\(/.*\)/[^/]*$#\1#p'
	} >"$TMP_DIR/dirs-raw"

	: >"$TMP_DIR/dirs"
	while IFS= read -r d; do
		case $d in
		/*) ;;
		*) continue ;; # entrée relative du PATH : ignorée
		esac
		c=$(canon_dir "$d")
		[ -n "$c" ] && printf '%s\n' "$c" >>"$TMP_DIR/dirs"
	done <"$TMP_DIR/dirs-raw"
	sort -u "$TMP_DIR/dirs" >"$TMP_DIR/dirs-uniq"

	std_canon=$(canon_dir "$BIN_DIR")
	while IFS= read -r d; do
		for name in $SCRIPTS; do
			f=$d/$name
			[ -f "$f" ] || continue
			v=$(version_of "$f")
			case $name in
			ntfy-send.sh)
				record info - "ntfy-send.sh ${v:-version ?}" "$f"
				;;
			*)
				if [ "$d" = "$std_canon" ]; then
					class=standard
				else
					class=AUTRE
				fi
				record script "$class" "script ${v:-version ?}" "$f" "$f"
				;;
			esac
		done
	done <"$TMP_DIR/dirs-uniq"
}

# Éléments qui ne bloquent pas l'installation : configurations, sauvegardes.
detect_others() {
	if [ -e "$NTFY_CONF" ]; then
		perms=$(ls -ldn -- "$NTFY_CONF" 2>/dev/null)
		read -r fmode _links owner _rest <<EOF
$perms
EOF
		case "$fmode:$owner" in
		-r[w-]-------:0 | -r[w-]-------.:0)
			record info - 'conf ntfy (0600 root)' "$NTFY_CONF"
			;;
		*)
			record info - "conf ntfy (droits $fmode, uid $owner)" "$NTFY_CONF"
			record warn - "droits à corriger : chmod 600 $NTFY_CONF ; chown root:root $NTFY_CONF" "$NTFY_CONF"
			;;
		esac
	fi

	# needrestart charge conf.d dans l'ordre alphabétique : en cas de
	# fichiers multiples, le dernier qui fixe $nrconf{restart} l'emporte.
	nset=0
	last=''
	for f in "$NR_CONF_DIR"/*.conf; do
		[ -f "$f" ] || continue
		# Le $ entre apostrophes est voulu : c'est du texte Perl littéral.
		# shellcheck disable=SC2016
		if grep -q '^[[:space:]]*\$nrconf{restart}' "$f"; then
			record info - 'conf needrestart (restart)' "$f"
			nset=$((nset + 1))
			last=$f
		elif [ "$f" = "$NR_CONF" ]; then
			record info - 'conf needrestart' "$f"
		fi
	done
	if [ "$nset" -gt 1 ]; then
		record warn - "$nset fichiers fixent \$nrconf{restart}, le dernier chargé l'emporte" "$last"
	fi

	[ ! -d "$BACKUP_ROOT" ] || record info - 'sauvegardes' "$BACKUP_ROOT"
	[ ! -f "$OLD_CRON_BAK" ] || record info - 'sauvegarde laissée par la 0.1.0' "$OLD_CRON_BAK"

	n_arch=0
	last_arch=''
	for f in "$ARCHIVE_DIR/$ARCHIVE_PREFIX"*.tar.gz; do
		[ -f "$f" ] || continue
		n_arch=$((n_arch + 1))
		last_arch=$f
	done
	if [ "$n_arch" -gt 0 ]; then
		record info - "archives de configuration ($n_arch)" "$last_arch"
	fi
}

# Dresse l'inventaire et en déduit STATUS :
#   none      aucune trace (hook, tâche planifiée, unité, script)
#   standard  toutes les traces sont aux emplacements de l'installeur
#   other     au moins une trace ailleurs, sous un autre nom ou en double
detect() {
	: >"$TMP_DIR/inventory"
	detect_apt
	detect_cron
	detect_units
	detect_scripts
	detect_others

	TRACES=$(grep -c -E '^(hook|cron|unit|script)[|]' "$TMP_DIR/inventory")
	OTHERS=$(grep -c -E '^(hook|cron|unit|script)[|]AUTRE[|]' "$TMP_DIR/inventory")
	if [ "$TRACES" -eq 0 ]; then
		STATUS=none
	elif [ "$OTHERS" -eq 0 ]; then
		STATUS=standard
	else
		STATUS=other
	fi
}

# Nombre de traces d'une nature donnée. Appelée par inventory_ok(), donc
# indirectement par check() (SC2317).
#   $1 : nature (hook, cron, unit, script)
# shellcheck disable=SC2317
count_kind() {
	grep -c "^$1[|]" "$TMP_DIR/inventory"
}

print_inventory() {
	say "Inventaire needrestart-ntfy (archive $VERSION) :"
	if [ "$TRACES" -gt 0 ]; then
		say '  Traces (bloquent une nouvelle installation) :'
		awk -F '|' '$1 ~ /^(hook|cron|unit|script)$/ {
			printf "    %-9s %-26s %s\n", $2, $3, $4
		}' "$TMP_DIR/inventory"
	fi
	if grep -q -E '^(info|warn)[|]' "$TMP_DIR/inventory"; then
		say '  Autres éléments (ne bloquent pas) :'
		awk -F '|' '
			$1 == "info" { printf "    %-36s %s\n", $3, $4 }
			$1 == "warn" { printf "    ATTENTION : %s\n", $3 }
		' "$TMP_DIR/inventory"
	fi
	case $STATUS in
	none) say '  Bilan : aucune trace de needrestart-ntfy' ;;
	standard) say "  Bilan : installation standard ($TRACES trace(s))" ;;
	*) say "  Bilan : installation non standard ($OTHERS trace(s) marquée(s) AUTRE)" ;;
	esac
}

# Consigne de nettoyage manuel pour les traces de l'inventaire.
#   $1 : autre    seulement les traces marquées AUTRE
#        apres-p  les traces AUTRE que -p ne retire pas lui-même (simulation)
#        tout     toutes les traces restantes (contrôle final de -p)
print_cleanup() {
	awk -F '|' -v filter="$1" -v crontab="$CRONTAB" -v cmd="$CRON_CMD" \
		-v apt98="$APT_DIR/98needrestart-ntfy" -v apt99="$APT_DIR/99zz-needrestart-ntfy" '
		$1 !~ /^(hook|cron|unit|script)$/ { next }
		filter != "tout" && $2 != "AUTRE" { next }
		filter == "apres-p" && $1 == "cron" && index($4, crontab ":") == 1 && $5 == cmd { next }
		filter == "apres-p" && $1 == "hook" && (index($4, apt98 ":") == 1 || index($4, apt99 ":") == 1) { next }
		{
			where = $4; file = where; line = ""
			if (match(where, /:[0-9]+$/)) {
				file = substr(where, 1, RSTART - 1)
				line = substr(where, RSTART + 1)
			}
			if ($1 == "script") {
				printf "  rm -f %s\n", where
			} else if ($1 == "unit") {
				n = split(file, p, "/")
				printf "  systemctl disable --now %s   (et son timer éventuel)\n", p[n]
				printf "  rm -f %s ; systemctl daemon-reload\n", file
			} else if ($1 == "cron" && index(file, "/var/spool/cron/crontabs/") == 1) {
				n = split(file, p, "/")
				printf "  crontab -u %s -e   (ligne %s)\n", p[n], line
			} else if (line == "") {
				printf "  apt-config dump | grep needrestart-ntfy-apt   (hook défini hors de /etc/apt)\n"
			} else {
				printf "  vi +%s %s\n", line, file
			}
		}' "$TMP_DIR/inventory"
}

# -----------------------------------------------------------------------------
# Vérifications préalables (aucune modification avant leur succès)
# -----------------------------------------------------------------------------

need_root() {
	uid=$(id -u)
	[ "$uid" -eq 0 ] || die 2 "à lancer en root"
}

# Commandes nécessaires à l'inventaire (tous les modes).
check_inventory_tools() {
	missing=''
	for cmd in apt-config awk sed grep find sort cut tr wc date mktemp tar; do
		command -v "$cmd" >/dev/null 2>&1 || missing="$missing $cmd"
	done
	[ -z "$missing" ] || die 2 "commandes manquantes :$missing"
}

# Prérequis de l'installation et de la mise à jour.
preflight() {
	missing=''
	for cmd in curl iconv logger install cmp sha256sum; do
		command -v "$cmd" >/dev/null 2>&1 || missing="$missing $cmd"
	done
	[ -x "$NR_BIN" ] || missing="$missing needrestart"
	[ -z "$missing" ] ||
		die 2 "commandes manquantes :$missing (apt install needrestart curl)"

	# Intégrité de l'archive : tout ce qui sera installé est contrôlé.
	[ -r "$FILES/SHA256SUMS" ] || die 2 "archive incomplète : files/SHA256SUMS absent"
	if ! (cd -- "$FILES" && sha256sum -c --quiet SHA256SUMS) >/dev/null 2>&1; then
		die 2 "archive altérée : vérifiez avec (cd files && sha256sum -c SHA256SUMS)"
	fi

	for name in $SCRIPTS; do
		[ -r "$FILES$BIN_DIR/$name" ] || die 2 "fichier absent de l'archive : files$BIN_DIR/$name"
	done
	for h in $HOOKS; do
		[ -r "$FILES$APT_DIR/$h" ] || die 2 "fichier absent de l'archive : files$APT_DIR/$h"
	done
	grep -qx 'NTFY_TOPIC=' "$FILES$NTFY_CONF" 2>/dev/null ||
		die 2 "modèle files$NTFY_CONF absent ou sans ligne NTFY_TOPIC="
	[ -r "$FILES$NR_CONF" ] || die 2 "fichier absent de l'archive : files$NR_CONF"

	if [ -n "$CONF_SRC" ]; then
		if [ ! -f "$CONF_SRC" ] || [ ! -r "$CONF_SRC" ]; then
			die 2 "fichier de configuration illisible : $CONF_SRC"
		fi
	fi

	# Le hook de needrestart doit exister : les nôtres l'encadrent.
	[ -r "$APT_DIR/99needrestart" ] ||
		warn "$APT_DIR/99needrestart absent : l'ordre des hooks sera à vérifier"
}

# -----------------------------------------------------------------------------
# Déploiement des fichiers
# -----------------------------------------------------------------------------

# Script versionné : installé s'il manque, mis à jour s'il est plus ancien,
# conservé s'il est identique, plus récent ou modifié localement.
#   $1 : nom du script
deploy_script() {
	src=$FILES$BIN_DIR/$1
	dst=$BIN_DIR/$1
	new=$(version_of "$src")

	if [ ! -e "$dst" ]; then
		act install -o root -g root -m 0755 "$src" "$dst" &&
			done_msg "installé : $dst ($new)"
		CHANGES=$((CHANGES + 1))
		return 0
	fi
	if cmp -s "$src" "$dst"; then
		say "à jour : $dst ($new)"
		return 0
	fi

	old=$(version_of "$dst")
	if [ -n "$old" ]; then
		order=$(ver_cmp "$old" "$new")
	else
		order=-1 # version illisible : le fichier est remplacé
	fi
	case $order in
	-1)
		backup_file "$dst"
		act install -o root -g root -m 0755 "$src" "$dst" &&
			done_msg "mis à jour : $dst (${old:-version inconnue} -> $new)"
		CHANGES=$((CHANGES + 1))
		;;
	0)
		warn "$dst modifié localement (même version $old) : conservé"
		;;
	*)
		warn "$dst en version $old, plus récente que $new : conservé"
		;;
	esac
}

# Fichier non versionné (hook APT) : installé s'il manque, remplacé (après
# sauvegarde) si son contenu diffère.
#   $1 : nom du fichier dans apt.conf.d
deploy_hook() {
	src=$FILES$APT_DIR/$1
	dst=$APT_DIR/$1
	if [ ! -e "$dst" ]; then
		act install -o root -g root -m 0644 "$src" "$dst" &&
			done_msg "installé : $dst"
		CHANGES=$((CHANGES + 1))
	elif cmp -s "$src" "$dst"; then
		say "à jour : $dst"
	else
		backup_file "$dst"
		act install -o root -g root -m 0644 "$src" "$dst" &&
			done_msg "remplacé : $dst (contenu différent)"
		CHANGES=$((CHANGES + 1))
	fi
}

# -----------------------------------------------------------------------------
# Topic ntfy
# -----------------------------------------------------------------------------

# Suffixe aléatoire pris dans l'alphabet autorisé par ntfy.
#   $1 : longueur
random_suffix() {
	s=''
	while [ "${#s}" -lt "$1" ]; do
		chunk=$(dd if=/dev/urandom bs=64 count=1 2>/dev/null | tr -dc 'A-Za-z0-9_-')
		s=$s$chunk
	done
	printf '%s' "$s" | cut -c "1-$1"
}

# Demande le topic, en clair, puis le fait confirmer. Entrée vide : topic
# généré. Au plus TOPIC_TRIES essais. Le topic retenu est placé dans TOPIC.
# Code de retour non nul si aucun topic n'est retenu.
ask_topic() {
	TOPIC=''
	tries=0
	say ''
	say "Le topic ntfy fait office de mot de passe : évitez un nom devinable."
	while [ "$tries" -lt "$TOPIC_TRIES" ]; do
		tries=$((tries + 1))
		printf 'Topic ntfy (vide = génération automatique) : '
		read -r topic || return 1
		generated=0
		if [ -z "$topic" ]; then
			topic=$TOPIC_PREFIX$(random_suffix "$TOPIC_RANDOM_LEN")
			generated=1
		fi
		case $topic in
		*[!A-Za-z0-9_-]*)
			say "Caractères autorisés : A-Z a-z 0-9 _ -"
			continue
			;;
		*) ;; # alphabet correct
		esac
		if [ "${#topic}" -gt 64 ]; then
			say "64 caractères au maximum (${#topic} saisis)."
			continue
		fi
		say "Topic retenu : $topic"
		if [ "$generated" -eq 1 ]; then
			say "Notez-le : abonnez votre téléphone à ce topic dans l'appli ntfy."
		fi
		printf 'Confirmer ? [o/N] '
		read -r answer || return 1
		case $answer in
		o | O | oui | Oui | OUI)
			TOPIC=$topic
			return 0
			;;
		*) say 'Topic non retenu.' ;;
		esac
	done
	return 1
}

# Écrit /etc/ntfy-send.conf à partir du modèle, avec le topic retenu. Le
# topic passe par l'environnement d'awk, pas par sa ligne de commande.
#   $1 : topic
write_ntfy_conf() {
	tmp=$TMP_DIR/ntfy-send.conf
	NTFY_NEW_TOPIC=$1 awk '
		$0 == "NTFY_TOPIC=" { print "NTFY_TOPIC=" ENVIRON["NTFY_NEW_TOPIC"]; next }
		{ print }
	' "$FILES$NTFY_CONF" >"$tmp" &&
		install -o root -g root -m 0600 "$tmp" "$NTFY_CONF" &&
		say "installé : $NTFY_CONF (topic $1)"
}

# Archive de configuration la plus récente de ~ (les noms horodatés se
# trient dans l'ordre chronologique), vide s'il n'y en a aucune.
latest_archive() {
	last=''
	for f in "$ARCHIVE_DIR/$ARCHIVE_PREFIX"*.tar.gz; do
		[ ! -f "$f" ] || last=$f
	done
	printf '%s' "$last"
}

# Propose de restaurer la configuration depuis la dernière archive de ~, en
# ne recréant que les fichiers absents. Hors terminal, la restauration se
# fait : c'est la réponse par défaut. Une archive qui contient autre chose
# que les deux fichiers attendus est ignorée.
# Code de retour 0 si /etc/ntfy-send.conf existe à la fin.
restore_from_archive() {
	arch=$(latest_archive)
	[ -n "$arch" ] || return 1
	if [ "$DRY_RUN" -eq 1 ]; then
		say "[simulation] proposerait de restaurer la configuration de $arch"
		return 0
	fi
	if [ -t 0 ]; then
		printf 'Restaurer la configuration archivée (%s) ? [O/n] ' "$arch"
		read -r answer || answer=''
		case $answer in
		n | N | non | Non | NON) return 1 ;;
		*) ;; # oui par défaut
		esac
	else
		say "Pas de terminal : restauration de $arch (réponse par défaut)."
	fi

	if ! tar -tzf "$arch" >"$TMP_DIR/archive-list" 2>/dev/null; then
		warn "archive illisible, ignorée : $arch"
		return 1
	fi
	while IFS= read -r member; do
		case $member in
		"${NTFY_CONF#/}" | "${NR_CONF#/}") ;;
		*)
			warn "contenu inattendu ($member) dans $arch : archive ignorée"
			return 1
			;;
		esac
	done <"$TMP_DIR/archive-list"
	if ! { mkdir -p "$TMP_DIR/restore" && tar -xzf "$arch" -C "$TMP_DIR/restore" 2>/dev/null; }; then
		warn "extraction impossible, archive ignorée : $arch"
		return 1
	fi

	# Un lien symbolique dans l'archive est refusé : install copierait sa
	# cible.
	src=$TMP_DIR/restore$NTFY_CONF
	if [ ! -e "$NTFY_CONF" ] && [ -f "$src" ] && [ ! -L "$src" ]; then
		install -o root -g root -m 0600 "$src" "$NTFY_CONF" &&
			say "restauré : $NTFY_CONF (depuis $arch)"
	fi
	src=$TMP_DIR/restore$NR_CONF
	if [ ! -e "$NR_CONF" ] && [ -f "$src" ] && [ ! -L "$src" ]; then
		mkdir -p "$NR_CONF_DIR" &&
			install -o root -g root -m 0644 "$src" "$NR_CONF" &&
			say "restauré : $NR_CONF (depuis $arch)" &&
			NR_RESTORED=1
	fi
	[ -e "$NTFY_CONF" ]
}

# Configuration ntfy : jamais écrasée. Ordre : conf existante, puis -f,
# puis dernière archive de ~ (sur confirmation), puis saisie dans un
# terminal, sinon modèle vide.
install_ntfy_conf() {
	if [ -e "$NTFY_CONF" ]; then
		say "conservé : $NTFY_CONF"
		[ -z "$CONF_SRC" ] || say "  (option -f ignorée)"
		return 0
	fi
	CHANGES=$((CHANGES + 1))
	if [ -n "$CONF_SRC" ]; then
		act install -o root -g root -m 0600 "$CONF_SRC" "$NTFY_CONF" &&
			done_msg "installé : $NTFY_CONF (copie de $CONF_SRC)"
		return 0
	fi
	if restore_from_archive; then
		return 0
	fi
	if [ "$DRY_RUN" -eq 1 ]; then
		say "[simulation] demanderait le topic ntfy, puis créerait $NTFY_CONF (0600)"
		return 0
	fi
	if [ -t 0 ] && ask_topic; then
		write_ntfy_conf "$TOPIC"
		return 0
	fi
	install -o root -g root -m 0600 "$FILES$NTFY_CONF" "$NTFY_CONF" &&
		say "installé : $NTFY_CONF (modèle)"
	warn "renseignez NTFY_TOPIC dans $NTFY_CONF, sinon aucune notification ne partira"
}

# -----------------------------------------------------------------------------
# Configuration needrestart et cron
# -----------------------------------------------------------------------------

# Configuration needrestart : jamais écrasée, elle peut contenir des
# exclusions locales.
install_nr_conf() {
	if [ "$WITH_LOGIND" -eq 1 ] &&
		! grep -qF 'qr(^systemd-logind) => 0' "$NR_CONF_MAIN" 2>/dev/null; then
		warn "clé qr(^systemd-logind) introuvable dans $NR_CONF_MAIN : l'override logind risque d'être sans effet"
	fi

	if [ -e "$NR_CONF" ]; then
		[ "$NR_RESTORED" -eq 1 ] || say "conservé : $NR_CONF"
		# Le $ entre apostrophes est voulu : c'est du texte Perl littéral.
		# shellcheck disable=SC2016
		if [ "$WITH_LOGIND" -eq 1 ] &&
			! grep -q '^\$nrconf{override_rc}{qr(^systemd-logind)} = 1;' "$NR_CONF"; then
			warn "option -l : ajoutez vous-même la ligne logind dans $NR_CONF"
		fi
		return 0
	fi

	CHANGES=$((CHANGES + 1))
	act mkdir -p "$NR_CONF_DIR"
	if [ "$WITH_LOGIND" -eq 1 ]; then
		# Version du modèle avec la ligne logind décommentée.
		tmp=$TMP_DIR/50-autorestart.conf
		# Le $ entre apostrophes est voulu : c'est du texte Perl littéral.
		# shellcheck disable=SC2016
		sed 's/^#\(\$nrconf{override_rc}{qr(^systemd-logind)} = 1;\)$/\1/' \
			"$FILES$NR_CONF" >"$tmp"
		act install -o root -g root -m 0644 "$tmp" "$NR_CONF" &&
			done_msg "installé : $NR_CONF (avec relancement de systemd-logind)"
	else
		act install -o root -g root -m 0644 "$FILES$NR_CONF" "$NR_CONF" &&
			done_msg "installé : $NR_CONF"
	fi
}

# Ligne cron : ajoutée seulement si aucune ligne active n'appelle déjà le
# script standard dans /etc/crontab.
install_cron() {
	if [ ! -f "$CRONTAB" ]; then
		warn "$CRONTAB absent (cron installé ?) : ajoutez vous-même la ligne \"$CRON_LINE\""
		return 0
	fi
	if active_cron_line; then
		say "conservé : ligne cron de $CRONTAB"
		return 0
	fi
	CHANGES=$((CHANGES + 1))
	if [ "$DRY_RUN" -eq 1 ]; then
		say "[simulation] ajout dans $CRONTAB :"
		say "  $CRON_MARK"
		say "  $CRON_LINE"
		return 0
	fi
	backup_file "$CRONTAB"
	printf '%s\n%s\n' "$CRON_MARK" "$CRON_LINE" >>"$CRONTAB" &&
		say "ajouté : ligne cron dans $CRONTAB"
}

# -----------------------------------------------------------------------------
# Vérifications finales
# -----------------------------------------------------------------------------

check() {
	# $1 : description, la commande suit
	desc=$1
	shift
	if "$@"; then
		say "  ok     $desc"
	else
		say "  ÉCHEC  $desc"
		FAILURES=$((FAILURES + 1))
	fi
}

# Les fonctions *_ok et nr_conf_loaded sont appelées indirectement par
# check(), ce que l'analyseur ne voit pas (SC2317).

# shellcheck disable=SC2317
scripts_ok() {
	# -V : script conservé d'une version antérieure à la 0.4.0.
	for name in $SCRIPTS; do
		"$BIN_DIR/$name" -v >/dev/null 2>&1 ||
			"$BIN_DIR/$name" -V >/dev/null 2>&1 || return 1
	done
}

# Les hooks doivent encadrer celui de needrestart : before, apt-pinvoke,
# after, dans cet ordre.
# shellcheck disable=SC2317
apt_order_ok() {
	dump=$(apt-config dump 2>/dev/null) || return 1
	printf '%s\n' "$dump" | grep -q 'needrestart-ntfy-apt.sh mark' || return 1
	nb=$(printf '%s\n' "$dump" | grep -n 'needrestart-ntfy-apt.sh before' | head -n 1 | cut -d: -f1)
	np=$(printf '%s\n' "$dump" | grep -n 'apt-pinvoke' | head -n 1 | cut -d: -f1)
	na=$(printf '%s\n' "$dump" | grep -n 'needrestart-ntfy-apt.sh after' | head -n 1 | cut -d: -f1)
	[ -n "$nb" ] && [ -n "$np" ] && [ -n "$na" ] &&
		[ "$nb" -lt "$np" ] && [ "$np" -lt "$na" ]
}

# needrestart doit charger le fichier de conf.d. Le mode liste (-r l) ne
# relance rien.
# shellcheck disable=SC2317
nr_conf_loaded() {
	"$NR_BIN" -v -r l 2>&1 | grep -qF "eval $NR_CONF"
}

# shellcheck disable=SC2317
ntfy_conf_ok() {
	"$BIN_DIR/ntfy-send.sh" -n -t install 'test' >/dev/null
}

# Après installation, l'inventaire doit être standard et complet : trois
# hooks, une seule ligne cron, deux scripts.
# shellcheck disable=SC2317
inventory_ok() {
	detect
	[ "$STATUS" = standard ] || return 1
	n_hook=$(count_kind hook)
	n_cron=$(count_kind cron)
	n_script=$(count_kind script)
	[ "$n_hook" -eq 3 ] && [ "$n_cron" -eq 1 ] && [ "$n_script" -eq 2 ]
}

verify() {
	say ''
	say 'Vérifications :'
	check 'scripts installés et exécutables' scripts_ok
	check 'ordre des hooks APT (mark, before, apt-pinvoke, after)' apt_order_ok
	check "chargement de $NR_CONF par needrestart" nr_conf_loaded
	check "configuration ntfy valide ($NTFY_CONF)" ntfy_conf_ok
	check 'inventaire standard (3 hooks, 1 ligne cron, 2 scripts)' inventory_ok
	if [ "$SEND_TEST" -eq 1 ]; then
		check 'notification de test envoyée' "$BIN_DIR/needrestart-ntfy.sh" -f
	fi
}

# -----------------------------------------------------------------------------
# Modes
# -----------------------------------------------------------------------------

# Installation (MODE=install) ou mise à jour (MODE=update).
do_install() {
	preflight
	detect

	case "$MODE:$STATUS" in
	install:none | update:none | update:standard) ;;
	install:standard)
		print_inventory
		say ''
		say "Installation existante : rien n'a été modifié."
		say "  Mise à jour      : $PROG -u   (--upgrade)"
		say "  Désinstallation  : $PROG -p   (--purge)"
		exit 3
		;;
	*)
		print_inventory
		say ''
		say "Installation non standard : rien n'a été modifié."
		say "Retirez d'abord les traces marquées AUTRE :"
		print_cleanup autre
		exit 3
		;;
	esac

	if [ "$MODE" = update ]; then
		if [ "$STATUS" = none ]; then
			say 'Aucune installation trouvée : installation complète.'
		else
			print_inventory
		fi
		say ''
	fi

	for name in $SCRIPTS; do
		deploy_script "$name"
	done
	for h in $HOOKS; do
		deploy_hook "$h"
	done
	install_ntfy_conf
	install_nr_conf
	install_cron

	if [ "$CHANGES" -eq 0 ]; then
		say ''
		say "Rien à faire : l'installation est déjà en version $VERSION."
	fi

	if [ "$DRY_RUN" -eq 1 ]; then
		say ''
		say 'Simulation : vérifications non effectuées.'
		return 0
	fi
	verify
}

# Inventaire seul : 0 si aucune trace, 3 sinon.
do_status() {
	detect
	print_inventory
	[ "$STATUS" = none ] || exit 3
}

# Premier appel (fichier:ligne) à ntfy-send.sh hors de needrestart-ntfy :
# tâches planifiées, unités systemd, scripts locaux. Vide si aucun.
ntfy_send_user() {
	{
		cron_files
		find /etc/systemd/system -type f 2>/dev/null
		for d in /usr/local/sbin /usr/local/bin /root/bin; do
			for f in "$d"/*; do
				[ ! -f "$f" ] || printf '%s\n' "$f"
			done
		done
	} >"$TMP_DIR/ntfy-scan"
	: >"$TMP_DIR/ntfy-users"
	while IFS= read -r f; do
		case $f in
		"$BIN_DIR/ntfy-send.sh" | "$BIN_DIR/needrestart-ntfy.sh" | "$BIN_DIR/needrestart-ntfy-apt.sh") ;;
		*) scan_calls "$f" '#' 'ntfy-send[.]sh' >>"$TMP_DIR/ntfy-users" ;;
		esac
	done <"$TMP_DIR/ntfy-scan"
	sed -n '1s/[|].*//p' "$TMP_DIR/ntfy-users"
}

# Liste dans $TMP_DIR/purge ce que -p supprimera : uniquement ce que
# l'installeur connaît, à ses emplacements, versions précédentes comprises.
build_purge_list() {
	: >"$TMP_DIR/purge"
	for h in $HOOKS; do
		f=$APT_DIR/$h
		[ -f "$f" ] || continue
		if grep -q "$PAT_APT" "$f"; then
			printf '%s\n' "$f" >>"$TMP_DIR/purge"
		else
			warn "$f n'appelle pas needrestart-ntfy-apt.sh : conservé"
		fi
	done
	for name in $TRIGGER_SCRIPTS; do
		[ ! -f "$BIN_DIR/$name" ] || printf '%s\n' "$BIN_DIR/$name" >>"$TMP_DIR/purge"
	done
	if [ -f "$CRONTAB" ] && { active_cron_line || grep -qxF "$CRON_MARK" "$CRONTAB"; }; then
		printf '%s\n' "ligne cron de $CRONTAB" >>"$TMP_DIR/purge"
	fi
	if [ -z "$NTFY_USER" ]; then
		for f in "$BIN_DIR/ntfy-send.sh" "$NTFY_CONF"; do
			[ ! -e "$f" ] || printf '%s\n' "$f" >>"$TMP_DIR/purge"
		done
	fi
	for f in "$NR_CONF" "$BACKUP_ROOT" "$OLD_CRON_BAK" "$STATE_DIR"; do
		[ ! -e "$f" ] || printf '%s\n' "$f" >>"$TMP_DIR/purge"
	done
}

# Confirmation de la désinstallation, sauf avec -y. Hors terminal, -y est
# obligatoire : rien n'est supprimé sans accord.
confirm_purge() {
	[ "$ASSUME_YES" -eq 0 ] || return 0
	[ -t 0 ] ||
		die 2 "désinstallation hors terminal : ajoutez -y (--yes) pour confirmer"
	n=$(wc -l <"$TMP_DIR/purge" | tr -d ' ')
	printf 'Désinstaller needrestart-ntfy (%s élément(s)) ? [o/N] ' "$n"
	read -r answer || answer=''
	case $answer in
	o | O | oui | Oui | OUI) say '' ;;
	*)
		say "Abandon : rien n'a été modifié."
		exit 4
		;;
	esac
}

# Décide de l'archivage : --no-archive l'interdit, -a ou -y l'imposent,
# sinon la question est posée (oui par défaut).
want_archive() {
	[ "$NO_ARCHIVE" -eq 0 ] || return 1
	if [ "$ARCHIVE" -eq 1 ] || [ "$ASSUME_YES" -eq 1 ]; then
		return 0
	fi
	printf 'Archiver la configuration avant suppression ? [O/n] '
	read -r answer || answer=''
	case $answer in
	n | N | non | Non | NON) return 1 ;;
	*) return 0 ;;
	esac
}

# Archive les fichiers de configuration présents dans
# ~/needrestart-ntfy-config-AAAAMMJJ-HHMMSS.tar.gz (0600 : elle contient le
# topic), chemins relatifs à / pour une restauration par tar -C /. En cas
# d'échec, le script s'arrête avant toute suppression.
archive_config() {
	set --
	[ ! -f "$NTFY_CONF" ] || set -- ${1+"$@"} "${NTFY_CONF#/}"
	[ ! -f "$NR_CONF" ] || set -- ${1+"$@"} "${NR_CONF#/}"
	if [ $# -eq 0 ]; then
		say 'Aucune configuration à archiver.'
		return 0
	fi
	[ -d "$ARCHIVE_DIR" ] ||
		die 2 "archivage impossible : $ARCHIVE_DIR n'existe pas ; rien n'a été supprimé"
	dest=$ARCHIVE_DIR/$ARCHIVE_PREFIX$(date +%Y%m%d-%H%M%S).tar.gz
	if tar -czf "$TMP_DIR/config.tar.gz" -C / "$@" 2>/dev/null &&
		tar -tzf "$TMP_DIR/config.tar.gz" >/dev/null 2>&1 &&
		install -o root -g root -m 0600 "$TMP_DIR/config.tar.gz" "$dest"; then
		ARCHIVE_FILE=$dest
		say "archivé : $dest"
	else
		die 2 "archivage impossible ($dest) : rien n'a été supprimé"
	fi
}

# Retire de /etc/crontab les lignes actives qui appellent le script standard
# et le commentaire posé par l'installeur. cat > conserve le propriétaire et
# les droits de la crontab.
remove_cron_line() {
	[ -f "$CRONTAB" ] || return 0
	active_cron_line || grep -qxF "$CRON_MARK" "$CRONTAB" || return 0
	awk -v cmd="$CRON_CMD" -v mark="$CRON_MARK" '
		$0 == mark { next }
		{
			line = $0
			sub(/^[ \t]+/, "", line)
			if (substr(line, 1, 1) != "#" && index($0, cmd) > 0) next
			print
		}' "$CRONTAB" >"$TMP_DIR/crontab" &&
		cat -- "$TMP_DIR/crontab" >"$CRONTAB" &&
		say "retiré : ligne cron de $CRONTAB"
}

# Suppression, dans un ordre sûr : les hooks d'abord, pour qu'apt cesse
# d'appeler le script avant sa disparition.
purge_items() {
	for h in $HOOKS; do
		f=$APT_DIR/$h
		if [ -f "$f" ] && grep -q "$PAT_APT" "$f"; then
			rm -f -- "$f" && say "supprimé : $f"
		fi
	done
	for name in $TRIGGER_SCRIPTS; do
		f=$BIN_DIR/$name
		if [ -f "$f" ]; then
			rm -f -- "$f" && say "supprimé : $f"
		fi
	done
	remove_cron_line
	if [ -z "$NTFY_USER" ]; then
		for f in "$BIN_DIR/ntfy-send.sh" "$NTFY_CONF"; do
			if [ -e "$f" ]; then
				rm -f -- "$f" && say "supprimé : $f"
			fi
		done
	fi
	for f in "$NR_CONF" "$OLD_CRON_BAK"; do
		if [ -e "$f" ]; then
			rm -f -- "$f" && say "supprimé : $f"
		fi
	done
	for d in "$BACKUP_ROOT" "$STATE_DIR"; do
		if [ -d "$d" ]; then
			rm -rf -- "$d" && say "supprimé : $d"
		fi
	done
}

# Désinstallation complète (-p) de ce que l'installeur connaît, comme apt
# purge. Ne sont jamais supprimés : les traces non standard (AUTRE), les
# dossiers d'archive extraits, les archives de configuration de ~, et
# ntfy-send.sh avec sa conf si une autre tâche les utilise.
do_uninstall() {
	detect
	print_inventory
	say ''

	NTFY_USER=$(ntfy_send_user)
	build_purge_list
	if [ -s "$TMP_DIR/purge" ]; then
		say 'Seront supprimés :'
		sed 's/^/  /' "$TMP_DIR/purge"
	else
		say 'Rien à supprimer.'
	fi
	if [ -n "$NTFY_USER" ]; then
		say "Conservés : $BIN_DIR/ntfy-send.sh et $NTFY_CONF (utilisés par $NTFY_USER)"
	fi
	say ''

	if [ "$DRY_RUN" -eq 1 ]; then
		if [ -s "$TMP_DIR/purge" ] && { [ -f "$NTFY_CONF" ] || [ -f "$NR_CONF" ]; }; then
			if [ "$NO_ARCHIVE" -eq 1 ]; then
				say '[simulation] configuration non archivée (--no-archive)'
			else
				say "[simulation] archivage de la configuration dans $ARCHIVE_DIR/${ARCHIVE_PREFIX}AAAAMMJJ-HHMMSS.tar.gz (oui par défaut)"
			fi
		fi
		if [ "$OTHERS" -gt 0 ]; then
			say 'À retirer à la main (non standard) :'
			print_cleanup apres-p
		fi
		say "Simulation : rien n'a été modifié."
		return 0
	fi

	if [ -s "$TMP_DIR/purge" ]; then
		confirm_purge
		if { [ -f "$NTFY_CONF" ] || [ -f "$NR_CONF" ]; } && want_archive; then
			archive_config
		fi
		purge_items
	fi

	if [ -n "$ARCHIVE_FILE" ]; then
		say ''
		say "Configuration archivée : $ARCHIVE_FILE"
		say "  (restauration proposée à la prochaine installation)"
	fi

	say ''
	detect
	if [ "$STATUS" = none ]; then
		say 'Contrôle final : plus aucune trace de needrestart-ntfy.'
		return 0
	fi
	say 'Contrôle final : des traces subsistent, à retirer à la main :'
	print_cleanup tout
	exit 3
}

# -----------------------------------------------------------------------------
# Programme principal
# -----------------------------------------------------------------------------

# Options longues : traduites en options courtes, puis analysées par
# getopts, qui ne connaît que les options courtes. La boucle parcourt les
# arguments d'origine tout en reconstruisant la liste traduite.
# "for arg; do" et ${1+"$@"} évitent l'erreur "parameter not set" de posh
# (set -u) quand la liste des paramètres est vide.
for arg; do
	shift
	case $arg in
	--upgrade) set -- ${1+"$@"} -u ;;
	--check) set -- ${1+"$@"} -c ;;
	--purge) set -- ${1+"$@"} -p ;;
	--ntfy-conf=*) set -- ${1+"$@"} -f "${arg#*=}" ;;
	--ntfy-conf) set -- ${1+"$@"} -f ;;
	--logind) set -- ${1+"$@"} -l ;;
	--test) set -- ${1+"$@"} -t ;;
	--dry-run) set -- ${1+"$@"} -n ;;
	--yes) set -- ${1+"$@"} -y ;;
	--archive) set -- ${1+"$@"} -a ;;
	--no-archive) NO_ARCHIVE=1 ;; # forme longue seulement
	--help) set -- ${1+"$@"} -h ;;
	--version) set -- ${1+"$@"} -v ;;
	--) set -- ${1+"$@"} -- ;;
	--*) die 2 "option inconnue : $arg (voir $PROG --help)" ;;
	*) set -- ${1+"$@"} "$arg" ;;
	esac
done

# Le ":" initial rend getopts silencieux : les messages d'erreur sont
# produits ici, en français.
while getopts ':upcf:ltnyahv' opt; do
	case $opt in
	u) set_mode update ;;
	c) set_mode status ;;
	p) set_mode uninstall ;;
	f)
		[ -n "$OPTARG" ] || die 2 "option -f (--ntfy-conf) : fichier manquant"
		CONF_SRC=$OPTARG
		;;
	l) WITH_LOGIND=1 ;;
	t) SEND_TEST=1 ;;
	n) DRY_RUN=1 ;;
	y) ASSUME_YES=1 ;;
	a) ARCHIVE=1 ;;
	h)
		usage
		exit 0
		;;
	v)
		printf '%s %s\n' "$PROG" "$VERSION"
		exit 0
		;;
	# ":" : argument manquant (seule -f en attend un) ; "?" : option inconnue.
	*) unknown_option "$OPTARG" ;;
	esac
done
shift $((OPTIND - 1))

# Un argument restant vient souvent de l'ancien "-c fichier" de la 0.2.0.
[ $# -eq 0 ] ||
	die 2 "argument inattendu : $1 (la conf ntfy se passe avec -f fichier ; voir $PROG --help)"

case $MODE in
status | uninstall)
	if [ -n "$CONF_SRC" ] || [ "$WITH_LOGIND" -eq 1 ] || [ "$SEND_TEST" -eq 1 ]; then
		die 2 "les options -f, -l et -t ne servent qu'à l'installation et à la mise à jour"
	fi
	;;
*) ;; # install ou update
esac
if [ "$MODE" != uninstall ]; then
	[ "$ASSUME_YES" -eq 0 ] ||
		die 2 "l'option -y (--yes) ne sert qu'avec -p (--purge)"
	if [ "$ARCHIVE" -eq 1 ] || [ "$NO_ARCHIVE" -eq 1 ]; then
		die 2 "les options -a (--archive) et --no-archive ne servent qu'avec -p (--purge)"
	fi
fi
if [ "$ARCHIVE" -eq 1 ] && [ "$NO_ARCHIVE" -eq 1 ]; then
	die 2 "les options -a (--archive) et --no-archive s'excluent mutuellement"
fi

need_root
check_inventory_tools

TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/needrestart-ntfy-install.XXXXXX") ||
	die 2 "impossible de créer un répertoire temporaire"
trap cleanup 0
trap 'exit 1' HUP INT TERM

case $MODE in
status)
	do_status
	exit 0
	;;
uninstall)
	do_uninstall
	exit 0
	;;
*) do_install ;;
esac

say ''
if [ "$FAILURES" -gt 0 ]; then
	say "Bilan : $FAILURES vérification(s) en échec, $WARNINGS avertissement(s)."
	exit 1
fi
say "Bilan : terminé, $WARNINGS avertissement(s)."
exit 0
