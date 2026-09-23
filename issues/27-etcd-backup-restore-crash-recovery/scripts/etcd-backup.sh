#!/bin/bash
# =============================================================================
# etcd-backup.sh — take an etcd snapshot on a master and pull it to
# ~/etcd-snapshots/<timestamp>/. Works for the lab cluster (core@ masters,
# ~/.ssh/ocp4-key). Run from the admin host.
#
# Usage:  ./etcd-backup.sh                 # picks first master
#         ./etcd-backup.sh 192.168.29.22   # specific master
# Cron:   0 2 * * * /home/centos/.../etcd-backup.sh >> ~/etcd-snapshots/backup.log 2>&1
# =============================================================================
set -euo pipefail

MASTER="${1:-192.168.29.21}"
SSH="ssh -i ~/.ssh/ocp4-key -o StrictHostKeyChecking=accept-new core@${MASTER}"
TS=$(date +%Y%m%d-%H%M%S)
REMOTE_DIR="/home/core/assets/backup-${TS}"
LOCAL_DIR="${HOME}/etcd-snapshots/${TS}"

echo "[$(date)] Backing up etcd via ${MASTER} -> ${LOCAL_DIR}"

# cluster-backup.sh writes snapshot_<ts>.db + static_kuberesources_<ts>.tar.gz
$SSH "sudo /usr/local/bin/cluster-backup.sh ${REMOTE_DIR}"

mkdir -p "$LOCAL_DIR"
scp -i ~/.ssh/ocp4-key -r "core@${MASTER}:${REMOTE_DIR}/." "$LOCAL_DIR/"

echo "[$(date)] Pulled:"
ls -lh "$LOCAL_DIR"

# Keep last 7 backups
cd ~/etcd-snapshots
ls -1d 2*/ 2>/dev/null | sort | head -n -7 | xargs -r rm -rf
echo "[$(date)] Retention applied (last 7 kept). Done."
