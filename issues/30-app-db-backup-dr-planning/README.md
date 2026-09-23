# Issue 30 — Application/DB Backup-Restore & Multi-Region DR Planning

| Field | Detail |
|---|---|
| **Date** | 2026-09-23 |
| **Type** | Architecture/Design + Procedure — backup & disaster recovery |
| **Status** | Documented — ready for execution |
| **Scope** | Workloads, persistent volumes, and cluster state protection; DR strategy across regions |
| **Cluster** | lab.ocp.local (OCP 4.20.35, UPI/Proxmox, NFS storage, single site) |
| **Purpose** | Protect workloads, PVs and cluster state; define regional DR strategy |
| **Key best practices applied** | Off-peak backup windows, regular restore testing, cross-region replication |

---

## Why This Exists

- etcd snapshots (Issue 27) protect **cluster state** — they do NOT protect application PVs or give you per-app/per-namespace restore granularity.
- NFS `Retain` policy (Issue 23) preserves volumes on delete but is **not** a backup — no point-in-time, no off-site copy, no object restore.
- Single site = no DR today. This doc defines the target DR architecture (active-passive/active-active) so Day-0 decisions don't foreclose it.

## The three protection tiers

| Tier | What's protected | Tool | Coverage |
|---|---|---|---|
| **1. Cluster state** | etcd — every API object | `cluster-backup.sh` (Issue 27) | Whole-cluster DR |
| **2. App + PVs** | Namespaces, objects, persistent data | **Velero/OADP** → S3-compatible store | Per-app/namespace restore |
| **3. DB data** | Database contents | Logical dumps + PV snapshots | Point-in-time, app-consistent |

Enterprise alternatives where they exist: **Commvault, Veeam Kasten, NetBackup** — same tiers, richer catalog/policy engine (Guide Part 4).

## Quick Path

| Need | Go to |
|---|---|
| Install OADP + first backup | Guide Parts 2–3 + `manifests/` |
| Backup a database correctly | Guide Part 3.3 + `manifests/db-backup-cronjob.yaml` |
| Design regional DR | Guide Part 5 — strategy decision matrix |
| **Before deploying** | `checklists/pre-validation.md` — requirements, env, OADP, DB, DR-readiness gates |
| **After deploying** | `checklists/post-validation.md` — backup execution, restore drill, alerting, sign-off |
| Prove backups work | Guide Part 6.2 — restore drill procedure + `scripts/velero-backup-check.sh` |

## Files

```
30-app-db-backup-dr-planning/
├── README.md                              # This file
├── Backup-DR-Planning-Guide.md            # Full guide
├── manifests/
│   ├── oadp-install.yaml                  # OADP operator subscription + namespace
│   ├── dpa-velero.yaml                    # DataProtectionApplication (velero instance)
│   ├── backup-schedules.yaml              # daily app / weekly full schedules
│   └── db-backup-cronjob.yaml             # logical DB dump CronJob (Postgres example)
├── checklists/
│   ├── pre-validation.md                  # run BEFORE deploy — reqs/env/OADP/DB/DR gates
│   └── post-validation.md                 # run AFTER deploy — backup/restore/alert/DR sign-off
└── scripts/
    └── velero-backup-check.sh             # backup health + last-restore-test audit
```
