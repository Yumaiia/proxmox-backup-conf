Principe du script de sauvegarde :

Je veux sauvegarder la configuration de chaque noeud proxmox pour la synchroniser ensuite sur un partage SMB.
Le partage SMB est défini dans Proxmox VE, dans la vue datacenter.

Cette sauvegarde doit être lancée par une tâche cron (ou systemd ?) une fois par jour
Elle doit comprendre :
- Tout /etc
- Tout /var/lib/pve-cluster
- Un dump de /var/lib/pve-cluster/config.db (à la racine, nommé dump-config.db.sql)

Je veux un historique de 7 jours dans /var/backup/proxmox-backup-conf (sous-répertoire à créer s'il n'existe pas)

Et ensuite 
- vérifier que le patage cible existe (basé sur le nombre proxmox)
- sycnhroniser le contenu de /var/backup/proxmox-backup-conf vers PARTAGE/{clustername}/{nodename}
 
 