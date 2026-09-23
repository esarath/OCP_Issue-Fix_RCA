# Issue 27 — etcd Backup, Restore & Control-Plane Crash Recovery

| Field | Detail |
|---|---|
| **Date** | 2026-09-23 |
| **Type** | Procedure/Documentation — disaster recovery runbook |
| **Status** | Documented — ready for manual execution |
| **Scope** | Scheduled + on-demand etcd snapshots, restore to a previous cluster state, single-member and quorum-loss recovery |
| **Cluster** | lab.ocp.local (OCP 4.20.35, 3 masters + 2 workers, UPI on Proxmox) |
| **Risk if absent** | etcd holds ALL cluster state (every object, secret, config). No snapshot + quorum loss = total cluster rebuild |

---

## Why This Exists

- etcd is the **single source of truth** — if it's lost without a snapshot, every namespace, deployment, secret, and route is unrecoverable.
- With 3 masters the cluster tolerates **1** master failure. Two down = quorum lost = API dead until a restore.
- This is a **UPI cluster** — no machine API to auto-rebuild masters; etcd member recovery is manual.
- Snapshots already land in `~/etcd-snapshots/` ad hoc — this adds the full procedure + automation.

## Quick Path

| Scenario | Procedure |
|---|---|
| Take a backup right now | [Guide](ETCD-Backup-Restore-Guide.md) Part 2 — `cluster-backup.sh` on one master |
| Automate daily backups | [Guide](ETCD-Backup-Restore-Guide.md) Part 3 + `scripts/etcd-backup.sh` |
| One etcd member/pod crashed, cluster still up | [Guide](ETCD-Backup-Restore-Guide.md) Part 5 — member rebuild (quorum intact) |
| 2+ masters down / API dead / rollback needed | [Guide](ETCD-Backup-Restore-Guide.md) Part 6 — `cluster-restore.sh` full restore |
| Verify a backup is usable | [Guide](ETCD-Backup-Restore-Guide.md) Part 4 — `etcdctl snapshot status` |

## Golden rules

1. **Snapshot + `static_kuberesources` tarball must come from the SAME backup run** — never mix.
2. **Never restore a snapshot onto just one member while others still run the old cluster** — restore goes on ALL masters.
3. **Test a backup before you need it** — `snapshot status` + keep 2+ generations.
4. Backups contain **secrets in plaintext** — encrypt at rest / restrict access.

## Files

```
27-etcd-backup-restore-crash-recovery/
├── README.md                              # This file
├── ETCD-Backup-Restore-Guide.md           # Full step-by-step runbook
├── manifests/
│   └── etcd-backup-cronjob.yaml           # optional in-cluster scheduled backup
└── scripts/
    ├── etcd-backup.sh                     # host-side: snapshot on a master + pull to ~/etcd-snapshots
    └── etcd-health-check.sh               # member list + endpoint health + alarms
```
