#!/bin/sh
# =============================================================================
# needrestart-ntfy-apt.sh - Notifie par ntfy les services relancés
#                           automatiquement par needrestart après un
#                           passage de dpkg (apt, unattended-upgrades).
#
# Version : 0.4.0
#
# Appelé par trois hooks APT, dans cet ordre :
#
#   mark    DPkg::Pre-Invoke, avant dpkg : mémorise la taille actuelle de
#           /var/log/dpkg.log pour retrouver ensuite les paquets traités.
#   before  DPkg::Post-Invoke, juste AVANT celui de needrestart
#           (fichier 98needrestart-ntfy, lu avant 99needrestart) : relève
#           les services qui ont besoin d'être relancés.
#   after   DPkg::Post-Invoke, juste APRÈS celui de needrestart
#           (fichier 99zz-needrestart-ntfy) : relève les services encore en
#           attente. La différence donne les services relancés.
#
# Une notification n'est envoyée que si au moins un service ou un conteneur
# a été relancé. Avec les "minimal steps" d'unattended-upgrades, dpkg peut
# tourner plusieurs fois par mise à jour : une notification par passage.
#
# Ce script ne fait jamais échouer apt : en mode hook, il sort toujours avec
# le code 0 et signale ses erreurs sur la sortie d'erreur et dans syslog.
#
# Usage :
#   needrestart-ntfy-apt.sh mark|before|after
#   needrestart-ntfy-apt.sh -h | --help | -v | --version
#
# Dépendances : needrestart, ntfy-send.sh, awk, grep, tail, logger
#
# Variables d'environnement facultatives (utiles pour les tests) :
#   NR_BIN     chemin de needrestart        (défaut : /usr/sbin/needrestart)
#   NTFY_SEND  chemin de ntfy-send.sh       (défaut : /usr/local/sbin/ntfy-send.sh)
#   DPKG_LOG   journal de dpkg              (défaut : /var/log/dpkg.log)
#   NR_RUNDIR  drapeaux de needrestart      (défaut : /run/needrestart)
#   STATE_DIR  état entre les trois hooks   (défaut : /run/needrestart-ntfy)
#
# Écrit en shell POSIX : fonctionne sous dash, bash et posh.
# =============================================================================

# Une variable non définie est une erreur ; les codes de retour des
# commandes sont traités explicitement, d'où l'absence de "set -e".
set -u

# Locale C : motifs ASCII stricts et sortie de dpkg.log non traduite.
LC_ALL=C
export LC_ALL

umask 077

VERSION='0.4.0'
PROG='needrestart-ntfy-apt.sh'

NR_BIN=${NR_BIN:-/usr/sbin/needrestart}
NTFY_SEND=${NTFY_SEND:-/usr/local/sbin/ntfy-send.sh}
DPKG_LOG=${DPKG_LOG:-/var/log/dpkg.log}
NR_RUNDIR=${NR_RUNDIR:-/run/needrestart}
STATE_DIR=${STATE_DIR:-/run/needrestart-ntfy}

# Fichiers d'état, en mémoire vive (/run), effacés au redémarrage.
OFFSET_FILE=$STATE_DIR/dpkg-log-offset
BEFORE_FILE=$STATE_DIR/before
AFTER_FILE=$STATE_DIR/after

NL='
'

# -----------------------------------------------------------------------------
# Fonctions utilitaires
# -----------------------------------------------------------------------------

# Écrit un message sur la sortie d'erreur (visible dans la sortie d'apt) et
# dans le journal système.
#   $1 : priorité syslog (err, warning, info)
#   $2 : message
log() {
	printf '%s: %s\n' "$PROG" "$2" >&2
	logger -t "$PROG" -p "user.$1" -- "$2" 2>/dev/null || :
}

usage() {
	cat <<EOF
Usage : $PROG mark|before|after
        $PROG -h | --help | -v | --version

Hooks APT qui notifient par ntfy les services relancés par needrestart.
  mark    avant dpkg (DPkg::Pre-Invoke)
  before  après dpkg, avant needrestart (DPkg::Post-Invoke, 98needrestart-ntfy)
  after   après needrestart (DPkg::Post-Invoke, 99zz-needrestart-ntfy)
EOF
}

# Supprime les relevés before et after.
clear_lists() {
	rm -f -- "$BEFORE_FILE" "$AFTER_FILE"
}

# Lance needrestart en mode batch (qui ne relance jamais rien) et ne garde
# que les lignes des services et des conteneurs.
#   $1 : fichier de sortie
# Code de retour : celui de needrestart.
snapshot() {
	"$NR_BIN" -b >"$1.raw" 2>/dev/null
	rc=$?
	grep -E '^NEEDRESTART-(SVC|CONT): ' "$1.raw" >"$1" || :
	rm -f -- "$1.raw"
	return "$rc"
}

# Met en forme une liste "NEEDRESTART-XXX: nom" en lignes "  - nom".
#   $1 : fichier, $2 : clé (SVC ou CONT)
format_list() {
	awk -v key="NEEDRESTART-$2: " '
		index($0, key) == 1 { print "  - " substr($0, length(key) + 1) }
	' "$1"
}

# Compte les lignes d'une clé donnée.
#   $1 : fichier, $2 : clé (SVC ou CONT)
count_key() {
	grep -c "^NEEDRESTART-$2: " "$1" || :
}

# Extrait de dpkg.log les paquets installés, mis à jour ou supprimés depuis
# la position mémorisée par "mark". Si le journal a été renouvelé entre-temps
# (taille inférieure à la position), il est relu depuis le début.
list_packages() {
	[ -r "$DPKG_LOG" ] || return 0
	offset=0
	if [ -r "$OFFSET_FILE" ]; then
		offset=$(cat -- "$OFFSET_FILE")
	fi
	case $offset in
	'' | *[!0-9]*) offset=0 ;;
	*) ;; # position valide
	esac
	size=$(wc -c <"$DPKG_LOG" | tr -d ' ')
	[ "$size" -ge "$offset" ] || offset=0

	# Format de dpkg.log : date heure action paquet:arch ancienne nouvelle
	tail -c "+$((offset + 1))" -- "$DPKG_LOG" | awk '
		function name(p) { sub(/:.*/, "", p); return p }
		$3 == "upgrade" && $5 == $6 { print "  - " name($4) " " $5 " (réinstallé)"; next }
		$3 == "upgrade" { print "  - " name($4) " " $5 " -> " $6; next }
		$3 == "install" { print "  - " name($4) " " $6 " (nouveau)"; next }
		$3 == "remove" || $3 == "purge" { print "  - " name($4) " (supprimé)"; next }
	'
}

# -----------------------------------------------------------------------------
# Modes
# -----------------------------------------------------------------------------

# Avant dpkg : mémorise la taille de dpkg.log et efface un éventuel relevé
# laissé par un passage interrompu.
do_mark() {
	mkdir -p -- "$STATE_DIR" || {
		log err "impossible de créer $STATE_DIR"
		return 0
	}
	clear_lists
	if [ -r "$DPKG_LOG" ]; then
		wc -c <"$DPKG_LOG" | tr -d ' ' >"$OFFSET_FILE"
	else
		echo 0 >"$OFFSET_FILE"
	fi
}

# Après dpkg, avant needrestart. Les conditions reprennent celles
# d'apt-pinvoke : si needrestart ne va pas tourner, il n'y a rien à suivre.
do_before() {
	clear_lists
	[ -e "$NR_RUNDIR/unpacked" ] || return 0
	[ ! -e "$NR_RUNDIR/errored" ] || return 0
	[ -z "${NEEDRESTART_SUSPEND:-}" ] || return 0
	[ -x "$NR_BIN" ] || {
		log err "needrestart introuvable ou non exécutable : $NR_BIN"
		return 0
	}
	mkdir -p -- "$STATE_DIR" || {
		log err "impossible de créer $STATE_DIR"
		return 0
	}

	if ! snapshot "$BEFORE_FILE"; then
		log err "needrestart -b a échoué (relevé avant needrestart)"
		clear_lists
		return 0
	fi

	# Rien à relancer : inutile de relancer needrestart -b dans "after".
	[ -s "$BEFORE_FILE" ] || clear_lists
}

# Après needrestart : compare les deux relevés et notifie si besoin.
do_after() {
	[ -s "$BEFORE_FILE" ] || return 0

	if ! snapshot "$AFTER_FILE"; then
		log err "needrestart -b a échoué (relevé après needrestart)"
		clear_lists
		return 0
	fi

	# Lignes présentes avant et absentes après : services relancés.
	# Un fichier de motifs vide ne correspond à rien, donc avec -v toutes
	# les lignes de "before" sont gardées : c'est le résultat attendu.
	grep -vxF -f "$AFTER_FILE" "$BEFORE_FILE" >"$STATE_DIR/restarted" || :

	if [ ! -s "$STATE_DIR/restarted" ]; then
		clear_lists
		rm -f -- "$STATE_DIR/restarted"
		return 0
	fi

	body=''
	n=$(count_key "$STATE_DIR/restarted" SVC)
	if [ "$n" -gt 0 ]; then
		body="${body}Services relancés automatiquement (${n}) :${NL}"
		body="${body}$(format_list "$STATE_DIR/restarted" SVC)${NL}"
	fi
	n=$(count_key "$STATE_DIR/restarted" CONT)
	if [ "$n" -gt 0 ]; then
		body="${body}Conteneurs relancés (${n}) :${NL}"
		body="${body}$(format_list "$STATE_DIR/restarted" CONT)${NL}"
	fi

	# Ce que needrestart n'a pas relancé (liste override_rc ou échec).
	n=$(count_key "$AFTER_FILE" SVC)
	if [ "$n" -gt 0 ]; then
		body="${body}Restent à relancer à la main (${n}) :${NL}"
		body="${body}$(format_list "$AFTER_FILE" SVC)${NL}"
	fi

	pkgs=$(list_packages)
	if [ -n "$pkgs" ]; then
		n=$(printf '%s\n' "$pkgs" | wc -l | tr -d ' ')
		body="${body}Paquets traités par ce passage de dpkg (${n}) :${NL}${pkgs}${NL}"
	fi

	clear_lists
	rm -f -- "$STATE_DIR/restarted"

	if [ ! -x "$NTFY_SEND" ]; then
		log err "ntfy-send.sh introuvable ou non exécutable : $NTFY_SEND"
		return 0
	fi
	printf '%s' "$body" |
		"$NTFY_SEND" -t 'needrestart : services relancés' \
			-p default -g arrows_counterclockwise ||
		log err "échec de l'envoi de la notification"
	return 0
}

# -----------------------------------------------------------------------------
# Programme principal
# -----------------------------------------------------------------------------

case ${1:-} in
mark) do_mark ;;
before) do_before ;;
after) do_after ;;
-h | --help)
	usage
	exit 0
	;;
-v | --version)
	printf '%s %s\n' "$PROG" "$VERSION"
	exit 0
	;;
-V)
	printf '%s: option inconnue : -V (depuis la 0.4.0, version : -v ou --version)\n' "$PROG" >&2
	exit 2
	;;
*)
	usage >&2
	exit 2
	;;
esac

# En mode hook, ne jamais faire échouer apt.
exit 0
