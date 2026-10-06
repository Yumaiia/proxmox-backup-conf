#!/bin/bash
#
# proxmox-backup-conf - Sauvegarde quotidienne de la configuration d'un nœud Proxmox VE
#
#  1. Archive tar.gz contenant :
#       - /etc (y compris /etc/pve)
#       - var-lib-pve/config.db : copie cohérente de /var/lib/pve-cluster/config.db
#                                 via l'API backup de SQLite
#       - à la racine : dump-config.db.sql (dump SQL de cette copie)
#                       pvereport-<nœud>-<date>.txt (sortie de pvereport)
#  2. Rétention locale de N jours dans $BACKUP_DIR
#  3. Vérification du stockage Proxmox ($STORAGE_ID)
#  4. Synchronisation de $BACKUP_DIR vers <partage>/<cluster>/<nœud>
#
# Configuration : /etc/default/proxmox-backup-conf

set -Eeuo pipefail

VERSION=0.9.1

if [[ ${1:-} == "--version" ]]; then
    echo "proxmox-backup-conf $VERSION"
    exit 0
fi

CONFIG_FILE=/etc/default/proxmox-backup-conf

# Valeurs par défaut (surchargées par $CONFIG_FILE)
STORAGE_ID=""
BACKUP_DIR=/var/backup/proxmox-backup-conf
RETENTION_DAYS=7
PVE_DB=/var/lib/pve-cluster/config.db
PVEREPORT_TIMEOUT=300

if [[ -r $CONFIG_FILE ]]; then
    # shellcheck source=/dev/null
    . "$CONFIG_FILE"
fi

log() { echo "$*"; }
warn() { echo "AVERTISSEMENT : $*" >&2; }
die() { echo "ERREUR : $*" >&2; exit 1; }

# --- Pré-requis --------------------------------------------------------------

[[ $EUID -eq 0 ]] || die "ce script doit être lancé en root"

for cmd in tar gzip sqlite3 rsync pvesm mountpoint flock hostname timeout; do
    command -v "$cmd" >/dev/null 2>&1 || die "commande '$cmd' introuvable (apt install $cmd ?)"
done

[[ -n $STORAGE_ID ]] || die "STORAGE_ID non défini dans $CONFIG_FILE"
[[ $RETENTION_DAYS =~ ^[1-9][0-9]*$ ]] || die "RETENTION_DAYS invalide : '$RETENTION_DAYS'"
[[ -r $PVE_DB ]] || die "base $PVE_DB introuvable"

# Une seule exécution à la fois
exec 9>/run/proxmox-backup-conf.lock
flock -n 9 || die "une autre sauvegarde est déjà en cours"

# --- Identification du nœud et du cluster -------------------------------------

NODE_NAME=$(hostname -s)
CLUSTER_NAME=""
if [[ -r /etc/pve/corosync.conf ]]; then
    CLUSTER_NAME=$(awk '$1 == "cluster_name:" { print $2; exit }' /etc/pve/corosync.conf)
fi
CLUSTER_NAME=${CLUSTER_NAME:-standalone}

[[ -n $NODE_NAME ]] || die "impossible de déterminer le nom du nœud"

log "proxmox-backup-conf $VERSION - nœud : $NODE_NAME / cluster : $CLUSTER_NAME"

# --- Sauvegarde locale --------------------------------------------------------

umask 077
mkdir -p "$BACKUP_DIR"
chmod 700 "$BACKUP_DIR"

STAGING=$(mktemp -d "$BACKUP_DIR/.tmp.XXXXXX")
trap 'rm -rf "$STAGING"' EXIT

STAMP=$(date +%Y-%m-%d_%H%M%S)

# Copie cohérente de config.db : l'API backup de SQLite gère les écritures
# concurrentes de pmxcfs et intègre le journal WAL. /var/lib/pve-cluster
# n'est pas archivé tel quel : sa copie brute par tar ne serait pas fiable.
DB_COPY="$STAGING/var-lib-pve/config.db"
mkdir "$STAGING/var-lib-pve"
log "Copie de $PVE_DB"
sqlite3 -cmd ".timeout 30000" "$PVE_DB" ".backup '$DB_COPY'" \
    || die "échec de la copie de $PVE_DB"

integrity=$(sqlite3 "$DB_COPY" "PRAGMA integrity_check;")
[[ $integrity == "ok" ]] || die "la copie de config.db est corrompue : $integrity"

# Dump réalisé depuis la copie : config.db et le dump reflètent le même état.
log "Dump SQL de config.db"
sqlite3 "$DB_COPY" .dump > "$STAGING/dump-config.db.sql" \
    || die "échec du dump de config.db"

# Rapport de diagnostic : non bloquant, la sauvegarde passe avant.
# Le timeout évite un blocage si un stockage ne répond pas.
REPORT_NAME="pvereport-${NODE_NAME}-${STAMP}.txt"
REPORT_FILES=()
log "Génération de $REPORT_NAME"
if timeout "$PVEREPORT_TIMEOUT" /usr/bin/pvereport > "$STAGING/$REPORT_NAME" 2>&1; then
    REPORT_FILES=("$REPORT_NAME")
else
    warn "échec ou dépassement de délai de pvereport, rapport non inclus"
fi

ARCHIVE_NAME="${NODE_NAME}_${STAMP}.tar.gz"
log "Création de l'archive $ARCHIVE_NAME"

# /etc/pve est un montage FUSE (pmxcfs) : pas de --one-file-system, on veut
# l'inclure. Code retour 1 de tar = fichier modifié pendant la lecture,
# non bloquant.
rc=0
tar --create --gzip \
    --file "$STAGING/$ARCHIVE_NAME" \
    --warning=no-file-changed --warning=no-file-removed \
    -C / etc \
    -C "$STAGING" var-lib-pve dump-config.db.sql "${REPORT_FILES[@]}" \
    || rc=$?
(( rc <= 1 )) || die "échec de tar (code $rc)"

gzip --test "$STAGING/$ARCHIVE_NAME" || die "archive invalide"
mv "$STAGING/$ARCHIVE_NAME" "$BACKUP_DIR/"
log "Archive créée : $BACKUP_DIR/$ARCHIVE_NAME ($(du -h "$BACKUP_DIR/$ARCHIVE_NAME" | cut -f1))"

# --- Rétention ----------------------------------------------------------------

# Seuil = RETENTION_DAYS jours moins 2 h, pour absorber le décalage aléatoire
# du timer : on garde ainsi exactement RETENTION_DAYS archives quotidiennes.
max_age_min=$(( RETENTION_DAYS * 1440 - 120 ))
find "$BACKUP_DIR" -maxdepth 1 -type f -name "${NODE_NAME}_*.tar.gz" \
    -mmin "+$max_age_min" -print -delete | sed 's/^/Suppression : /'

# --- Vérification du partage --------------------------------------------------

# pvesm status active (monte) le stockage si nécessaire.
storage_line=$(pvesm status --storage "$STORAGE_ID" 2>/dev/null | awk 'NR > 1') \
    || die "stockage '$STORAGE_ID' introuvable ou désactivé sur ce nœud"
storage_type=$(awk '{ print $2 }' <<<"$storage_line")
storage_status=$(awk '{ print $3 }' <<<"$storage_line")

[[ $storage_status == "active" ]] || die "le stockage '$STORAGE_ID' n'est pas actif ($storage_status)"

# Chemin du stockage d'après /etc/pve/storage.cfg (sections "<type>: <id>")
SHARE_PATH=$(awk -v id="$STORAGE_ID" '
    /^[a-z]+: / { in_section = ($2 == id); next }
    in_section && $1 == "path" { print $2; exit }
' /etc/pve/storage.cfg)
if [[ -z $SHARE_PATH ]]; then
    case $storage_type in
        nfs|cifs|cephfs|glusterfs) SHARE_PATH=/mnt/pve/$STORAGE_ID ;;
        *) die "le stockage '$STORAGE_ID' (type $storage_type) n'a pas de chemin de fichiers" ;;
    esac
fi
[[ -d $SHARE_PATH ]] || die "$SHARE_PATH introuvable"

# Stockage réseau : indispensable, sinon rsync écrirait sur le disque local.
# Pour un stockage dir, c'est son option is_mountpoint qui conditionne "active".
case $storage_type in
    nfs|cifs|cephfs|glusterfs)
        mountpoint -q "$SHARE_PATH" || die "$SHARE_PATH n'est pas monté" ;;
esac

log "Stockage $STORAGE_ID ($storage_type) : $SHARE_PATH"

# --- Synchronisation ----------------------------------------------------------

DEST="$SHARE_PATH/${CLUSTER_NAME:?}/${NODE_NAME:?}"
mkdir -p "$DEST"

log "Synchronisation vers $DEST"
# Pas de -a : CIFS ne gère ni propriétaires ni permissions POSIX.
rsync -rt --delete --modify-window=2 \
    --exclude '.tmp.*' \
    "$BACKUP_DIR/" "$DEST/" \
    || die "échec de la synchronisation vers $DEST"

log "Sauvegarde terminée"
