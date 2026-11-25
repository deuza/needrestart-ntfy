#!/bin/sh
# =============================================================================
# ntfy-send.sh - Envoie une notification vers un serveur ntfy
#                (ntfy.sh ou instance auto-hébergée)
#
# Version : 0.4.0
#
# Usage :
#   ntfy-send.sh [-n] [-c fichier] [-t titre] [-p priorité] [-g tags] [message...]
#   commande | ntfy-send.sh [-t titre] [-p priorité] [-g tags]
#
# Chaque option a une forme longue (--conf, --title, --priority, --tags,
# --dry-run, --help, --version), voir --help. Aucune option en majuscule.
#
# Sans message en argument, ou avec "-" comme unique argument, le message
# est lu sur l'entrée standard. Les options doivent précéder le message ;
# "--" marque la fin des options (message qui commence par "-").
#
# Codes de sortie :
#   0  notification acceptée par le serveur (ou simulation réussie avec -n)
#   1  échec de l'envoi (réseau, délai dépassé, erreur HTTP)
#   2  erreur d'usage ou de configuration
#
# Dépendances : curl (>= 7.76 pour --fail-with-body), iconv (libc-bin),
#               logger, dd, cut, tr, sed, mktemp
#
# Écrit en shell POSIX : fonctionne sous dash, bash et posh.
# =============================================================================

# Une variable non définie est une erreur : cela évite qu'une faute de frappe
# dans un nom de variable passe inaperçue. Les erreurs des commandes sont
# traitées explicitement, d'où l'absence de "set -e".
set -u

# Locale C : les classes de caractères des motifs (A-Z, a-z...) restent
# strictement ASCII, quelle que soit la locale de l'appelant (cron, systemd).
LC_ALL=C
export LC_ALL

# Les fichiers temporaires (configuration curl contenant le topic et le
# jeton) ne doivent être lisibles que par leur propriétaire.
umask 077

VERSION='0.4.0'
PROG='ntfy-send.sh'

# -----------------------------------------------------------------------------
# Réglages
# -----------------------------------------------------------------------------

# Fichier de configuration par défaut. Il contient le topic, qui fait office
# de mot de passe sur ntfy.sh : il doit appartenir à root et n'être lisible
# que par lui (droits 0600 ou 0400), sinon le script refuse de l'utiliser.
CONF='/etc/ntfy-send.conf'

# Taille maximale du corps du message, en octets. Au-delà de 4096 octets,
# ntfy transforme le message en pièce jointe : une marge est gardée pour la
# mention de troncature ajoutée en fin de message.
MAX_BYTES=4000

# Taille maximale du titre, en octets.
MAX_TITLE_BYTES=200

# Délais curl, en secondes. Un serveur injoignable ne doit pas bloquer
# l'appelant (hook APT, cron) plus d'une minute :
#   - MAX_TIME borne chaque tentative ;
#   - aucune nouvelle tentative ne démarre après RETRY_MAX_TIME secondes ;
#   - pire cas : RETRY_MAX_TIME + MAX_TIME = 45 secondes.
CONNECT_TIMEOUT=10
MAX_TIME=15
RETRIES=2
RETRY_MAX_TIME=30

# Valeurs par défaut, surchargées par le fichier de configuration.
NTFY_SERVER='https://ntfy.sh'
NTFY_TOPIC=''
NTFY_TOKEN=''

# Valeurs par défaut des options de la ligne de commande.
TITLE=''
PRIORITY=''
TAGS=''
DRY_RUN=0

# Répertoire temporaire, créé plus loin et supprimé à la sortie.
TMP_DIR=''

# -----------------------------------------------------------------------------
# Fonctions utilitaires
# -----------------------------------------------------------------------------

# Écrit un message sur la sortie d'erreur et dans le journal système.
#   $1 : priorité syslog (err, warning, info)
#   $2 : message
log() {
	printf '%s: %s\n' "$PROG" "$2" >&2
	# L'absence de logger ne doit pas empêcher l'envoi de la notification.
	logger -t "$PROG" -p "user.$1" -- "$2" 2>/dev/null || :
}

# Journalise une erreur puis quitte.
#   $1 : code de sortie
#   $2 : message
die() {
	log err "$2"
	exit "$1"
}

# Supprime le répertoire temporaire. Appelée automatiquement à la sortie.
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
Usage : $PROG [options] [message...]
        commande | $PROG [options]

Options :
  -c, --conf FICHIER       fichier de configuration
                           (défaut : $CONF)
  -t, --title TITRE        titre de la notification, préfixé par
                           [nom de la machine]
  -p, --priority PRIORITÉ  1 à 5, ou min, low, default, high, max, urgent
  -g, --tags TAGS          tags ntfy séparés par des virgules
                           (ex. : warning,skull)
  -n, --dry-run            simulation : affiche la requête sans l'envoyer
  -h, --help               affiche cette aide
  -v, --version            affiche la version

Les formes longues acceptent aussi --option=valeur. Sans message en
argument (ou avec "-"), le message est lu sur l'entrée standard ; "--"
termine les options, pour un message qui commence par "-".
EOF
}

# Vrai si, dans un groupe d'options courtes (ex. "-nt"), la dernière lettre
# attend une valeur qui n'y est pas collée : l'argument suivant est alors
# cette valeur, à recopier sans le traduire.
#   $1 : groupe d'options, tiret compris
value_follows() {
	rest=${1#-}
	while [ -n "$rest" ]; do
		letter=${rest%"${rest#?}"}
		rest=${rest#?}
		case $letter in
		[ctpg])
			[ -z "$rest" ]
			return
			;;
		*) ;; # option sans valeur
		esac
	done
	return 1
}

# Option courte refusée par getopts : argument manquant ou option inconnue,
# avec un rappel pour l'ancienne option -V.
#   $1 : lettre de l'option
bad_option() {
	case $1 in
	c | t | p | g) die 2 "option -$1 : argument manquant (voir $PROG --help)" ;;
	V) die 2 "option inconnue : -V (depuis la 0.4.0, version : -v ou --version)" ;;
	*) die 2 "option inconnue : -$1 (voir $PROG --help)" ;;
	esac
}

# Supprime les séquences UTF-8 invalides ou incomplètes. iconv -c renvoie un
# code non nul dès qu'il a dû retirer quelque chose : c'est attendu, d'où le
# "|| :". Sans ce nettoyage, ntfy transformerait le message en pièce jointe.
utf8_clean() {
	iconv -c -f UTF-8 -t UTF-8 2>/dev/null || :
}

# Prépare un titre pour le fichier de configuration curl :
#   1. supprime les caractères de contrôle, dont CR et LF, ce qui empêche
#      toute injection d'en-tête HTTP supplémentaire ;
#   2. limite la longueur à MAX_TITLE_BYTES octets sans couper un caractère
#      UTF-8 en deux ;
#   3. échappe \ et " pour la syntaxe entre guillemets de curl --config.
#   $1 : titre brut
clean_title() {
	printf '%s' "$1" |
		tr -d '\000-\037\177' |
		cut -b "1-$MAX_TITLE_BYTES" |
		utf8_clean |
		sed 's/[\\"]/\\&/g'
}

# Vérifie que le fichier de configuration est un fichier ordinaire,
# appartenant à root, sans aucun droit pour le groupe ni pour les autres.
# ls -ln est utilisé car stat(1) n'est pas POSIX.
#   $1 : chemin du fichier
check_conf_perms() {
	perms=$(ls -ldn -- "$1" 2>/dev/null) ||
		die 2 "fichier de configuration introuvable : $1"

	# Champs de ls -ln : droits, liens, uid, gid, ...
	read -r mode _links owner _rest <<EOF
$perms
EOF

	case $mode in
	# 0600 ou 0400 ; un "." final signale seulement un contexte SELinux.
	# Un "+" (ACL) est refusé : il peut donner un accès à d'autres comptes.
	-r[w-]------- | -r[w-]-------.) ;;
	*)
		die 2 "droits trop ouverts ou type incorrect sur $1 ($mode) : chmod 600 $1"
		;;
	esac

	[ "$owner" = '0' ] ||
		die 2 "$1 doit appartenir à root (uid actuel : $owner)"
}

# Lit le fichier de configuration sans l'exécuter : seules les clés connues
# sont prises en compte, ce qui évite d'exécuter du code arbitraire.
# Format : CLE=valeur, une par ligne, sans indentation ; les lignes vides et
# celles commençant par # sont ignorées ; des guillemets simples ou doubles
# englobant la valeur sont retirés.
#   $1 : chemin du fichier
load_conf() {
	lineno=0
	# Le "|| [ -n ... ]" traite aussi une dernière ligne sans retour chariot.
	while IFS= read -r line || [ -n "$line" ]; do
		lineno=$((lineno + 1))

		case $line in
		'' | '#'*) continue ;;
		*=*) ;;
		*) die 2 "$1:$lineno : ligne invalide (CLE=valeur attendu)" ;;
		esac

		key=${line%%=*}
		val=${line#*=}

		case $val in
		\"*\")
			val=${val#\"}
			val=${val%\"}
			;;
		\'*\')
			val=${val#\'}
			val=${val%\'}
			;;
		*) ;; # valeur sans guillemets : conservée telle quelle
		esac

		case $key in
		NTFY_SERVER) NTFY_SERVER=$val ;;
		NTFY_TOPIC) NTFY_TOPIC=$val ;;
		NTFY_TOKEN) NTFY_TOKEN=$val ;;
		*) log warning "$1:$lineno : clé inconnue ignorée : $key" ;;
		esac
	done <"$1"
}

# Contrôle les valeurs issues de la configuration et des options. Les
# caractères autorisés sont volontairement restreints : ces valeurs sont
# écrites entre guillemets dans le fichier de configuration curl.
validate() {
	# Adresse du serveur : http(s), caractères d'URL simples, crochets
	# acceptés pour une adresse IPv6 littérale.
	NTFY_SERVER=${NTFY_SERVER%/}
	case $NTFY_SERVER in
	https://?* | http://?*) ;;
	*) die 2 "NTFY_SERVER doit commencer par https:// ou http://" ;;
	esac
	case $NTFY_SERVER in
	*[!]A-Za-z0-9.:/_[-]*)
		die 2 "NTFY_SERVER contient des caractères non autorisés"
		;;
	*) ;; # adresse acceptée
	esac

	# Topic : lettres, chiffres, _ et -, 64 caractères au maximum.
	case $NTFY_TOPIC in
	'') die 2 "NTFY_TOPIC absent du fichier de configuration" ;;
	*[!A-Za-z0-9_-]*) die 2 "NTFY_TOPIC : seuls A-Z a-z 0-9 _ - sont autorisés" ;;
	*) ;; # topic accepté, longueur vérifiée ci-dessous
	esac
	[ "${#NTFY_TOPIC}" -le 64 ] ||
		die 2 "NTFY_TOPIC dépasse 64 caractères"

	# Jeton d'accès facultatif, au format tk_...
	case $NTFY_TOKEN in
	'') ;;
	tk_*[!A-Za-z0-9_]* | tk_) die 2 "NTFY_TOKEN invalide" ;;
	tk_*) ;;
	*) die 2 "NTFY_TOKEN doit commencer par tk_" ;;
	esac

	# Priorité : chiffre de 1 à 5 ou nom reconnu par ntfy.
	case $PRIORITY in
	'' | [1-5] | min | low | default | high | max | urgent) ;;
	*) die 2 "priorité invalide : $PRIORITY" ;;
	esac

	# Tags : noms de tags ntfy, séparés par des virgules.
	case $TAGS in
	*[!A-Za-z0-9_,+-]*) die 2 "tags invalides : $TAGS" ;;
	*) ;; # tags acceptés (ou absents)
	esac
}

# -----------------------------------------------------------------------------
# Programme principal
# -----------------------------------------------------------------------------

# Options longues : traduites en options courtes pour getopts. Comme getopts,
# la traduction s'arrête au premier argument qui n'est pas une option (le
# message, ou "-") et après "--" : un message n'est jamais modifié. La
# valeur d'une option qui en attend une (-c, -t, -p, -g) est recopiée telle
# quelle, même si elle commence par "--".
# "for arg; do" et ${1+"$@"} évitent l'erreur "parameter not set" de posh
# (set -u) quand la liste des paramètres est vide.
end_opts=0
want_value=0
for arg; do
	shift
	if [ "$end_opts" -eq 1 ] || [ "$want_value" -eq 1 ]; then
		set -- ${1+"$@"} "$arg"
		want_value=0
		continue
	fi
	case $arg in
	--conf=*) set -- ${1+"$@"} -c "${arg#*=}" ;;
	--title=*) set -- ${1+"$@"} -t "${arg#*=}" ;;
	--priority=*) set -- ${1+"$@"} -p "${arg#*=}" ;;
	--tags=*) set -- ${1+"$@"} -g "${arg#*=}" ;;
	--conf | --title | --priority | --tags)
		case $arg in
		--conf) set -- ${1+"$@"} -c ;;
		--title) set -- ${1+"$@"} -t ;;
		--priority) set -- ${1+"$@"} -p ;;
		*) set -- ${1+"$@"} -g ;;
		esac
		want_value=1
		;;
	--dry-run) set -- ${1+"$@"} -n ;;
	--help) set -- ${1+"$@"} -h ;;
	--version) set -- ${1+"$@"} -v ;;
	--)
		set -- ${1+"$@"} --
		end_opts=1
		;;
	--*) die 2 "option inconnue : $arg (voir $PROG --help)" ;;
	-?*)
		set -- ${1+"$@"} "$arg"
		if value_follows "$arg"; then
			want_value=1
		fi
		;;
	*)
		# Premier argument qui n'est pas une option : le message commence.
		# Le "--" ajouté devant arrête getopts à cet endroit dans tous les
		# shells : celui de posh, contrairement à POSIX, continuerait sinon à
		# lire les options placées après le message.
		set -- ${1+"$@"} -- "$arg"
		end_opts=1
		;;
	esac
done

# Le ":" initial rend getopts silencieux : les messages d'erreur sont
# produits par bad_option, en français.
while getopts ':c:t:p:g:nhv' opt; do
	case $opt in
	c) CONF=$OPTARG ;;
	t) TITLE=$OPTARG ;;
	p) PRIORITY=$OPTARG ;;
	g) TAGS=$OPTARG ;;
	n) DRY_RUN=1 ;;
	h)
		usage
		exit 0
		;;
	v)
		printf '%s %s\n' "$PROG" "$VERSION"
		exit 0
		;;
	*) bad_option "$OPTARG" ;; # ":" (argument manquant) ou "?" (inconnue)
	esac
done
shift $((OPTIND - 1))

for cmd in curl iconv; do
	command -v "$cmd" >/dev/null 2>&1 ||
		die 2 "commande introuvable : $cmd"
done

check_conf_perms "$CONF"
load_conf "$CONF"
validate

# Le répertoire temporaire est supprimé à toute sortie, y compris sur
# interruption : le signal provoque un exit, qui déclenche le piège 0.
TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/ntfy-send.XXXXXX") ||
	die 2 "impossible de créer un répertoire temporaire"
trap cleanup 0
trap 'exit 1' HUP INT TERM

# Lecture du message : arguments, ou entrée standard.
if [ $# -eq 0 ] || { [ $# -eq 1 ] && [ "$1" = '-' ]; }; then
	cat >"$TMP_DIR/raw" || die 2 "lecture de l'entrée standard impossible"
else
	printf '%s\n' "$*" >"$TMP_DIR/raw"
fi

utf8_clean <"$TMP_DIR/raw" >"$TMP_DIR/body"

size=$(wc -c <"$TMP_DIR/body" | tr -d ' ')
[ "$size" -gt 0 ] || die 2 "message vide"

# Troncature : dd lit un fichier ordinaire, il renvoie donc exactement
# MAX_BYTES octets ; utf8_clean retire un éventuel caractère coupé en deux.
if [ "$size" -gt "$MAX_BYTES" ]; then
	dd if="$TMP_DIR/body" bs="$MAX_BYTES" count=1 2>/dev/null |
		utf8_clean >"$TMP_DIR/trunc"
	printf '\n[... message tronqué, %s octets à l'\''origine]\n' "$size" \
		>>"$TMP_DIR/trunc"
	mv -f -- "$TMP_DIR/trunc" "$TMP_DIR/body"
fi

# Titre : toujours préfixé par le nom de la machine, utile quand plusieurs
# serveurs publient sur le même topic.
host=$(uname -n)
if [ -n "$TITLE" ]; then
	title=$(clean_title "[$host] $TITLE")
else
	title=$(clean_title "[$host]")
fi

# Le topic (qui sert de mot de passe) et le jeton sont passés à curl par un
# fichier de configuration plutôt que sur la ligne de commande : sinon, ils
# seraient visibles par tous les comptes de la machine dans ps ou /proc.
{
	printf 'url = "%s/%s"\n' "$NTFY_SERVER" "$NTFY_TOPIC"
	printf 'header = "Title: %s"\n' "$title"
	if [ -n "$PRIORITY" ]; then
		printf 'header = "Priority: %s"\n' "$PRIORITY"
	fi
	if [ -n "$TAGS" ]; then
		printf 'header = "Tags: %s"\n' "$TAGS"
	fi
	if [ -n "$NTFY_TOKEN" ]; then
		printf 'header = "Authorization: Bearer %s"\n' "$NTFY_TOKEN"
	fi
} >"$TMP_DIR/curl.conf"

if [ "$DRY_RUN" -eq 1 ]; then
	# Le jeton est masqué ; le topic reste affiché pour permettre la
	# vérification de la configuration.
	printf '%s\n' '--- configuration curl ---'
	sed 's/\(Authorization: Bearer \).*"/\1tk_[masqué]"/' "$TMP_DIR/curl.conf"
	size=$(wc -c <"$TMP_DIR/body" | tr -d ' ')
	printf '%s\n' "--- corps (${size} octets) ---"
	cat "$TMP_DIR/body"
	exit 0
fi

# -q doit rester le premier argument : il fait ignorer un éventuel ~/.curlrc.
# --fail-with-body : un code HTTP d'erreur fait échouer curl, et la réponse
# JSON de ntfy (qui explique l'erreur) est conservée pour le journal.
if ! out=$(curl -q --config "$TMP_DIR/curl.conf" \
	--data-binary "@$TMP_DIR/body" \
	--proto '=http,https' \
	--connect-timeout "$CONNECT_TIMEOUT" --max-time "$MAX_TIME" \
	--retry "$RETRIES" --retry-max-time "$RETRY_MAX_TIME" \
	--silent --show-error --fail-with-body 2>&1); then
	die 1 "échec de l'envoi : $(printf '%s' "$out" | tr '\n' ' ')"
fi

exit 0
