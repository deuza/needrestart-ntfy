#!/bin/sh
# =============================================================================
# needrestart-ntfy.sh - Signale par ntfy ce que needrestart ne peut pas
#                       régler seul : noyau ou microcode en attente de
#                       redémarrage, services exclus du relancement
#                       automatique, conteneurs, sessions (en option).
#
# Version : 0.4.0
#
# Prévu pour cron, après le passage d'unattended-upgrades. Exemple de ligne
# pour /etc/crontab :
#   37 7 * * * root /usr/local/sbin/needrestart-ntfy.sh
#
# Usage :
#   needrestart-ntfy.sh [-s] [-f] [-n] [-h] [-v]
#
# Formes longues : --sessions, --force, --dry-run, --help, --version.
# Aucune option en majuscule.
#
# Sans rien à signaler, le script ne notifie rien et sort avec le code 0.
#
# Codes de sortie :
#   0  rien à signaler, ou notification envoyée
#   1  échec de needrestart ou de l'envoi de la notification
#   2  erreur d'usage ou d'environnement
#
# Dépendances : needrestart, ntfy-send.sh, logger, mktemp
#
# Variables d'environnement facultatives (utiles pour les tests) :
#   NR_BIN     chemin de needrestart   (défaut : /usr/sbin/needrestart)
#   NTFY_SEND  chemin de ntfy-send.sh  (défaut : /usr/local/sbin/ntfy-send.sh)
#
# Écrit en shell POSIX : fonctionne sous dash, bash et posh.
# =============================================================================

# Une variable non définie est une erreur ; les codes de retour des
# commandes sont traités explicitement, d'où l'absence de "set -e".
set -u

# Locale C : la sortie de needrestart -b n'est pas traduite, mais les motifs
# des "case" doivent rester strictement ASCII quelle que soit la locale.
LC_ALL=C
export LC_ALL

umask 077

VERSION='0.4.0'
PROG='needrestart-ntfy.sh'

NR_BIN=${NR_BIN:-/usr/sbin/needrestart}
NTFY_SEND=${NTFY_SEND:-/usr/local/sbin/ntfy-send.sh}

# Options de la ligne de commande
WITH_SESSIONS=0 # -s : signaler aussi les sessions utilisateur obsolètes
FORCE=0         # -f : notifier même s'il n'y a rien à signaler
DRY_RUN=0       # -n : transmettre -n à ntfy-send.sh (simulation)

TMP_DIR=''

# Retour à la ligne littéral, pour construire le corps du message.
NL='
'

# -----------------------------------------------------------------------------
# Fonctions utilitaires
# -----------------------------------------------------------------------------

# Écrit un message sur la sortie d'erreur et dans le journal système.
#   $1 : priorité syslog (err, warning, info)
#   $2 : message
log() {
	printf '%s: %s\n' "$PROG" "$2" >&2
	logger -t "$PROG" -p "user.$1" -- "$2" 2>/dev/null || :
}

# Journalise une erreur puis quitte.
#   $1 : code de sortie
#   $2 : message
die() {
	log err "$2"
	exit "$1"
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
Usage : $PROG [options]

Interroge needrestart en mode batch et envoie une notification ntfy si une
action manuelle est nécessaire.

Options :
  -s, --sessions   signaler aussi les sessions utilisateur obsolètes
                   (screen, shells...)
  -f, --force      notifier même s'il n'y a rien à signaler (test de la
                   chaîne)
  -n, --dry-run    simulation : affiche la notification sans l'envoyer
  -h, --help       affiche cette aide
  -v, --version    affiche la version
EOF
}

# Option courte refusée par getopts, avec un rappel pour l'ancienne -V.
#   $1 : lettre de l'option
bad_option() {
	case $1 in
	V) die 2 "option inconnue : -V (depuis la 0.4.0, version : -v ou --version)" ;;
	*) die 2 "option inconnue : -$1 (voir $PROG --help)" ;;
	esac
}

# Envoie la notification par ntfy-send.sh.
#   $1 : titre, $2 : priorité, $3 : tags, $4 : corps du message
send() {
	if [ "$DRY_RUN" -eq 1 ]; then
		printf '%s' "$4" | "$NTFY_SEND" -n -t "$1" -p "$2" -g "$3"
	else
		printf '%s' "$4" | "$NTFY_SEND" -t "$1" -p "$2" -g "$3"
	fi
}

# -----------------------------------------------------------------------------
# Programme principal
# -----------------------------------------------------------------------------

# Options longues : traduites en options courtes pour getopts. Ce script
# n'accepte aucun argument hors options.
# "for arg; do" et ${1+"$@"} évitent l'erreur "parameter not set" de posh
# (set -u) quand la liste des paramètres est vide.
for arg; do
	shift
	case $arg in
	--sessions) set -- ${1+"$@"} -s ;;
	--force) set -- ${1+"$@"} -f ;;
	--dry-run) set -- ${1+"$@"} -n ;;
	--help) set -- ${1+"$@"} -h ;;
	--version) set -- ${1+"$@"} -v ;;
	--) set -- ${1+"$@"} -- ;;
	--*) die 2 "option inconnue : $arg (voir $PROG --help)" ;;
	*) set -- ${1+"$@"} "$arg" ;;
	esac
done

# Le ":" initial rend getopts silencieux : les messages d'erreur sont
# produits par bad_option, en français.
while getopts ':sfnhv' opt; do
	case $opt in
	s) WITH_SESSIONS=1 ;;
	f) FORCE=1 ;;
	n) DRY_RUN=1 ;;
	h)
		usage
		exit 0
		;;
	v)
		printf '%s %s\n' "$PROG" "$VERSION"
		exit 0
		;;
	*) bad_option "$OPTARG" ;;
	esac
done
shift $((OPTIND - 1))
[ $# -eq 0 ] || die 2 "argument inattendu : $1 (voir $PROG --help)"

[ -x "$NR_BIN" ] || die 2 "needrestart introuvable ou non exécutable : $NR_BIN"
[ -x "$NTFY_SEND" ] || die 2 "ntfy-send.sh introuvable ou non exécutable : $NTFY_SEND"

TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/needrestart-ntfy.XXXXXX") ||
	die 2 "impossible de créer un répertoire temporaire"
trap cleanup 0
trap 'exit 1' HUP INT TERM

# Interrogation de needrestart. Le mode batch ne relance jamais rien et
# n'affiche aucun dialogue : il peut tourner sans risque depuis cron.
"$NR_BIN" -b >"$TMP_DIR/out" 2>"$TMP_DIR/err"
rc=$?
if [ "$rc" -ne 0 ]; then
	# L'échec lui-même mérite une notification : sinon, une panne de
	# needrestart passerait inaperçue jusqu'au jour où elle compte.
	err=$(tr '\n' ' ' <"$TMP_DIR/err")
	log err "needrestart -b a échoué (code $rc) : $err"
	send 'needrestart en échec' high warning \
		"needrestart -b a échoué (code $rc).${NL}${err}" || :
	exit 1
fi

# Analyse de la sortie, au format "NEEDRESTART-CLE: valeur".
ksta='' kcur='' kexp=''
ucsta='' uccur='' ucexp=''
svc='' nsvc=0
cont='' ncont=0
sess='' nsess=0

while IFS= read -r line || [ -n "$line" ]; do
	val=${line#*: }
	case $line in
	NEEDRESTART-KSTA:*) ksta=$val ;;
	NEEDRESTART-KCUR:*) kcur=$val ;;
	NEEDRESTART-KEXP:*) kexp=$val ;;
	NEEDRESTART-UCSTA:*) ucsta=$val ;;
	NEEDRESTART-UCCUR:*) uccur=$val ;;
	NEEDRESTART-UCEXP:*) ucexp=$val ;;
	NEEDRESTART-SVC:*)
		svc="${svc}  - ${val}${NL}"
		nsvc=$((nsvc + 1))
		;;
	NEEDRESTART-CONT:*)
		cont="${cont}  - ${val}${NL}"
		ncont=$((ncont + 1))
		;;
	NEEDRESTART-SESS:*)
		sess="${sess}  - ${val}${NL}"
		nsess=$((nsess + 1))
		;;
	*) ;; # VER, PID et lignes inconnues : ignorées
	esac
done <"$TMP_DIR/out"

# Construction du message. La priorité monte à "high" pour ce qui exige un
# redémarrage de la machine (noyau, microcode).
body=''
prio='default'

# KSTA : 0 inconnu, 1 à jour, 2 mise à jour compatible ABI, 3 nouvelle
# version. L'état 0 n'est pas signalé : il est permanent sur certaines
# machines (conteneurs) et produirait une alerte quotidienne inutile.
case $ksta in
3)
	body="${body}Noyau : nouvelle version en attente, redémarrage requis${NL}"
	body="${body}  actuel  : ${kcur}${NL}  attendu : ${kexp}${NL}"
	prio='high'
	;;
2)
	body="${body}Noyau : mise à jour compatible ABI en attente, redémarrage requis${NL}"
	body="${body}  actuel  : ${kcur}${NL}"
	prio='high'
	;;
*) ;; # 0, 1 ou absent : rien à signaler
esac

# UCSTA : 0 inconnu, 1 à jour, 2 obsolète.
if [ "$ucsta" = '2' ]; then
	body="${body}Microcode CPU obsolète, redémarrage requis${NL}"
	body="${body}  actuel     : ${uccur}${NL}  disponible : ${ucexp}${NL}"
	prio='high'
fi

# Avec $nrconf{restart} = 'a', les services encore listés ici sont ceux que
# needrestart refuse de relancer (liste override_rc) ou dont le relancement
# a échoué : ils demandent une intervention.
if [ "$nsvc" -gt 0 ]; then
	body="${body}Services à relancer à la main (${nsvc}) :${NL}${svc}"
fi

if [ "$ncont" -gt 0 ]; then
	body="${body}Conteneurs à relancer (${ncont}) :${NL}${cont}"
fi

if [ "$WITH_SESSIONS" -eq 1 ] && [ "$nsess" -gt 0 ]; then
	body="${body}Sessions obsolètes (${nsess}) :${NL}${sess}"
fi

title='needrestart : action requise'
tags='warning'
if [ -z "$body" ]; then
	[ "$FORCE" -eq 1 ] || exit 0
	title='needrestart : rien à signaler'
	tags='white_check_mark'
	# Priorité normale : un test de la chaîne doit se voir comme une vraie
	# alerte ("low" ne fait ni son ni vibration sur le téléphone).
	prio='default'
	body="Test de la chaîne de notification (option -f).${NL}"
fi

send "$title" "$prio" "$tags" "$body" ||
	die 1 "échec de l'envoi de la notification"

exit 0
