#!/bin/bash
# Installe proxmox-backup-conf sur le nœud courant (à lancer en root depuis ce répertoire)

set -Eeuo pipefail
cd "$(dirname "$0")"

[[ $EUID -eq 0 ]] || { echo "À lancer en root" >&2; exit 1; }

install -m 0755 proxmox-backup-conf.sh /usr/local/sbin/proxmox-backup-conf
install -m 0644 systemd/proxmox-backup-conf.service /etc/systemd/system/
install -m 0644 systemd/proxmox-backup-conf.timer /etc/systemd/system/

# Ne pas écraser une configuration existante
if [[ ! -e /etc/default/proxmox-backup-conf ]]; then
    install -m 0644 proxmox-backup-conf.default /etc/default/proxmox-backup-conf
fi

systemctl daemon-reload
systemctl enable --now proxmox-backup-conf.timer

if ! grep -q '^STORAGE_ID="..*"' /etc/default/proxmox-backup-conf; then
    echo
    echo "ATTENTION : renseigner STORAGE_ID dans /etc/default/proxmox-backup-conf"
fi

echo "Test manuel : systemctl start proxmox-backup-conf && journalctl -u proxmox-backup-conf -e"
