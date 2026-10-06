# proxmox-backup-conf

Sauvegarde quotidienne de la configuration d'un nœud **Proxmox VE**, avec historique local et copie vers un stockage déclaré dans Proxmox (SMB/CIFS, NFS, CephFS, répertoire…).

Le script s'installe sur chaque nœud et tourne via un timer systemd.

## Ce qui est sauvegardé

Chaque jour, une archive `<nœud>_AAAA-MM-JJ_HHMMSS.tar.gz`. Tout son contenu est regroupé dans un dossier `<nœud>-AAAA-MM-JJ_HHMMSS/` :

```
pve1-2026-10-06_023512/
├── etc/
├── var-lib-pve/config.db
├── dump-config.db.sql
└── pvereport-pve1-2026-10-06_023512.txt
```

| Élément | Contenu |
|---|---|
| `etc/` | Tout `/etc`, y compris `/etc/pve` (configuration du cluster, des VM et des conteneurs) |
| `var-lib-pve/config.db` | Copie cohérente de `/var/lib/pve-cluster/config.db`, la base du cluster, faite avec l'API de sauvegarde en ligne de SQLite |
| `dump-config.db.sql` | Dump SQL de cette même copie, lisible et réimportable |
| `pvereport-<nœud>-<date>.txt` | Sortie de `pvereport` : état du nœud (versions, stockages, réseau, VM…) au moment de la sauvegarde |

La copie de `config.db` est faite à chaud mais reste cohérente, même si `pmxcfs` écrit pendant ce temps. Son intégrité est vérifiée (`PRAGMA integrity_check`) avant l'archivage. Le répertoire `/var/lib/pve-cluster` n'est pas archivé tel quel : une copie brute de la base pendant que `pmxcfs` l'utilise ne serait pas fiable.

Si `pvereport` échoue ou dépasse 5 minutes, la sauvegarde continue sans le rapport, avec un avertissement dans le journal.

## Fonctionnement

1. Création de l'archive dans `/var/backup/proxmox-backup-conf`.
2. Suppression des archives locales plus anciennes que `RETENTION_DAYS` jours (7 par défaut).
3. Vérification du stockage cible :
   - il doit exister et être **actif** sur ce nœud (`pvesm status`) ;
   - pour un stockage réseau (`cifs`, `nfs`, `cephfs`, `glusterfs`), son chemin doit être un **point de montage**. Sans cela, la copie partirait sur le disque local.
4. Synchronisation miroir (`rsync --delete`) du répertoire local vers :

   ```
   <chemin du stockage>/<nom du cluster>/<nom du nœud>/
   ```

   Un nœud hors cluster utilise `standalone` comme nom de cluster.

Si le stockage est indisponible, l'archive locale est quand même créée, mais le service termine en échec.

## Prérequis

- Proxmox VE, accès root.
- Un stockage de type fichiers déclaré dans **Datacenter > Stockage** et disponible sur le nœud.
- `sqlite3` et `rsync`, normalement présents sur Proxmox VE. Le script vérifie ses dépendances au démarrage.

## Installation

Sur chaque nœud :

```bash
git clone https://github.com/Yumaiia/proxmox-backup-conf.git
cd proxmox-backup-conf
./install.sh
```

L'installeur :

- copie le script dans `/usr/local/sbin/proxmox-backup-conf` ;
- installe les unités `proxmox-backup-conf.service` et `proxmox-backup-conf.timer` ;
- crée `/etc/default/proxmox-backup-conf`, sans écraser une configuration existante ;
- active le timer.

Renseigner ensuite l'ID du stockage cible :

```bash
nano /etc/default/proxmox-backup-conf
```

## Configuration

`/etc/default/proxmox-backup-conf` :

| Variable | Défaut | Description |
|---|---|---|
| `STORAGE_ID` | *(obligatoire)* | ID du stockage Proxmox cible, tel qu'affiché dans Datacenter > Stockage |
| `BACKUP_DIR` | `/var/backup/proxmox-backup-conf` | Répertoire local des archives |
| `RETENTION_DAYS` | `7` | Nombre de jours d'historique conservés |

Le timer se déclenche chaque jour à 2h30, avec un décalage aléatoire de 30 minutes au plus, pour que les nœuds n'écrivent pas tous en même temps sur le stockage. Une exécution manquée (nœud éteint) est rattrapée au démarrage. Pour changer l'horaire :

```bash
systemctl edit proxmox-backup-conf.timer
```

## Utilisation

```bash
# Lancer une sauvegarde immédiatement
systemctl start proxmox-backup-conf

# Consulter les logs
journalctl -u proxmox-backup-conf -e

# Prochaine exécution planifiée
systemctl list-timers proxmox-backup-conf.timer

# Version installée
proxmox-backup-conf --version
```

## Restauration

Lister le contenu d'une archive, ou en extraire un élément dans un répertoire de travail :

```bash
tar -tzf pve1_2026-10-06_023512.tar.gz
mkdir /tmp/restore
tar -xzf pve1_2026-10-06_023512.tar.gz -C /tmp/restore \
    pve1-2026-10-06_023512/var-lib-pve/config.db \
    pve1-2026-10-06_023512/etc/pve/qemu-server
```

Les fichiers sont extraits dans `/tmp/restore/pve1-2026-10-06_023512/`.

Ne jamais extraire directement à la racine `/`. Pour restaurer `config.db` ou la configuration d'un cluster, suivre la documentation Proxmox VE sur le système de fichiers du cluster (`pmxcfs`).

## Sécurité

Les archives contiennent des données sensibles : `/etc/shadow`, les clés et tokens de `/etc/pve/priv`, les clés SSH de l'hôte, etc.

- En local, elles sont créées en mode `600` dans un répertoire en `700`.
- Sur le stockage cible, ces droits ne sont pas conservés, en particulier sur SMB/CIFS. **Restreindre l'accès au partage** aux seuls comptes qui en ont besoin.

## Désinstallation

```bash
systemctl disable --now proxmox-backup-conf.timer
rm /etc/systemd/system/proxmox-backup-conf.{service,timer}
rm /usr/local/sbin/proxmox-backup-conf /etc/default/proxmox-backup-conf
systemctl daemon-reload
```

Les archives présentes dans `/var/backup/proxmox-backup-conf` et sur le stockage cible sont conservées.
