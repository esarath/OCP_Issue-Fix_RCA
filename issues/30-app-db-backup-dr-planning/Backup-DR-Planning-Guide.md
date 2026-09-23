# Application & DB Backup/Restore + Multi-Region DR — Planning & Design

Protect workloads, persistent volumes, and cluster state; define the DR strategy. Pattern: **Velero/OADP for cluster resources + PVs**, enterprise backup where it exists, and a deliberate **active-passive vs active-active** DR choice.

> Placeholders in `<angle brackets>` — replace before running.

---

## Table of Contents

1. [What actually needs protecting](#part-0--what-actually-needs-protecting)
2. [Requirements first — RTO/RPO & workload tiers](#part-1--requirements-first)
3. [Velero/OADP — install & configure](#part-2--velerooadp--install--configure)
4. [Backup operations — including databases](#part-3--backup-operations)
5. [Enterprise backup integration](#part-4--enterprise-backup-integration)
6. [DR strategy across regions](#part-5--dr-strategy-across-regions)
7. [Best practices — scheduling, testing, replication](#part-6--best-practices)
8. [Implementation runbook for this cluster](#part-7--implementation-runbook)
9. [Troubleshooting](#part-8--troubleshooting)

---

## Part 0 — What actually needs protecting

Three distinct tiers — a common failure is assuming one covers the others:

| Tier | Contents | Tool | Granularity |
|---|---|---|---|
| **Cluster state** | etcd = every API object, secrets, config | `cluster-backup.sh` (Issue 27) | Whole cluster only |
| **App resources + PVs** | Deployments, Services, Routes, Secrets, **and volume data** | **Velero/OADP** | Per-namespace, per-app, per-PVC |
| **DB data** | Table contents, transaction consistency | Logical dumps (`pg_dump`/`mysqldump`) + volume backup | Point-in-time, app-consistent |

**Key boundary**: etcd backup restores *cluster state* to a point — it won't give you "restore just the `payments` namespace to yesterday." Velero does that. And neither guarantees a *consistent* database — that's what logical dumps add (Part 3.3).

## Part 1 — Requirements first

Backup/DR design = RTO/RPO math per workload. Classify before configuring:

| Tier | Example | RPO | RTO | Backup cadence | DR pattern |
|---|---|---|---|---|---|
| Critical | Payments DB, prod API | ≤ 15 min | ≤ 1 h | Continuous (WAL) + 6h Velero | Active-passive replication or active-active |
| Important | Jenkins, internal apps | ≤ 24 h | ≤ 4 h | Daily Velero | Backup-restore to DR site |
| Standard | Dev/sandbox | ≤ 7 days | best effort | Weekly | Rebuild from GitOps |

> Every backup schedule in `manifests/` derives from this table — don't deploy a cadence you haven't justified.

## Part 2 — Velero/OADP: install & configure

OADP = Red Hat's supported Velero packaging (operator + plugins for OCP-specific resources like Routes, BuildConfigs, SCCs).

### 2.1 The backup target — S3-compatible object storage (required)

Velero stores object backups + volume data in object storage:

| Target | When |
|---|---|
| AWS S3 | Cloud deployments |
| **MinIO / Ceph RGW / StorageGRID** | On-prem — **this cluster's option** (deploy MinIO on svc-infra or in-cluster) |
| Azure Blob / GCS | Via respective provider plugins |

MinIO quickstart for the lab (one VM or in-cluster with NFS PVC):

```bash
# In-cluster minimal MinIO (lab-grade — 20Gi NFS-backed)
oc new-project velero-storage
oc apply -n velero-storage -f https://raw.githubusercontent.com/minio/minio/master/docs/orchestration/kubernetes/minio-standalone-pvc.yaml
# create bucket 'velero-bucket' via mc/console, note access keys
```

### 2.2 Install

```bash
oc apply -f manifests/oadp-install.yaml           # ns + operatorgroup + subscription
oc wait --for=condition=Available -n openshift-adp deploy/oadp-operator-controller-manager --timeout=180s

oc create secret generic cloud-credentials -n openshift-adp \
  --from-file=cloud=./credentials-velero          # aws-format keypair file

oc apply -f manifests/dpa-velero.yaml             # the Velero instance
oc get pods -n openshift-adp                      # velero + node-agent pods
oc get backupstoragelocation -n openshift-adp     # must be Available
```

### 2.3 PV data strategy — the decision that matters most

| Method | How | NFS-compatible? | Speed |
|---|---|---|---|
| **CSI snapshots** | Snapshot the volume via CSI driver | ❌ `nfs-storage` has no CSI snapshotter | Fast |
| **nodeAgent / fs-backup** (restic/kopia) | DaemonSet streams pod files to S3 | ✅ **works on any volume incl. NFS** | Slower, more network I/O |

This cluster's `nfs-storage` provisioner has **no CSI snapshot support** — `dpa-velero.yaml` therefore enables `nodeAgent` with `defaultVolumesToFsBackup: true`. If a CSI-capable storage class is added later (Ceph/LVM TopoLVM), prefer snapshots for PVs.

## Part 3 — Backup operations

### 3.1 Schedules (off-peak — Part 6.1)

`manifests/backup-schedules.yaml`: full cluster daily 03:30, critical namespaces every 6h. Etcd backup runs 02:00 (Issue 27) — staggered so they don't compete for node I/O.

### 3.2 Ad-hoc / pre-change backup

```bash
# Before any risky change — namespaces AND their PVs
oc create -n openshift-adp -f - <<EOF
apiVersion: velero.io/v1
kind: Backup
metadata: {name: pre-change-$(date +%Y%m%d)}
spec:
  includedNamespaces: ["<ns>"]
  defaultVolumesToFsBackup: true
  ttl: 168h
EOF
oc get backup pre-change-<date> -n openshift-adp   # watch for phase: Completed
```

### 3.3 Databases — the consistency problem

A filesystem backup of a DB volume can catch it mid-transaction → corrupted restore. **Two layers, always:**

1. **Logical dump** — `manifests/db-backup-cronjob.yaml` (`pg_dumpall` daily → PVC that Velero then backs up). Always restorable, version-portable.
2. **Velero hooks** for crash-consistency on the PV backup:

```yaml
# on the DB pod's container spec:
template:
  metadata:
    annotations:
      pre.hook.backup.velero.io/container: db
      pre.hook.backup.velero.io/command: '["/bin/sh","-c","pg_isready && psql -c \"SELECT pg_backup_start();\""]'
      post.hook.backup.velero.io/container: db
      post.hook.backup.velero.io/command: '["/bin/sh","-c","psql -c \"SELECT pg_backup_stop();\""]'
      # simpler lab variant: CHECKPOINT + flush
      # pre:  psql -c 'CHECKPOINT;'
```

For MySQL: `FLUSH TABLES WITH READ LOCK` pre-hook; MongoDB: `fsyncLock`. Redis: RDB/AOF persistence on, `BGSAVE` pre-hook.

### 3.4 Restore — the operation you actually care about

```bash
# Restore a whole namespace from latest backup
oc create -n openshift-adp -f - <<EOF
apiVersion: velero.io/v1
kind: Restore
metadata: {name: restore-<ns>-$(date +%Y%m%d)}
spec:
  backupName: <backup-name>
  includedNamespaces: ["<ns>"]
  restorePVs: true
  # namespaceMapping: {<ns>: <ns>-restored}   # restore to a COPY namespace — safest for drills
EOF

# Point-in-time object only
spec:
  backupName: <backup>
  includedResources: [secrets, configmaps]
```

Always restore to a **mapped copy namespace** for drills — proves the backup without touching prod.

## Part 4 — Enterprise backup integration

If the enterprise already owns Commvault/Veeam/NetBackup, don't fight it — Velero/OADP still works for cluster-object backup, while the enterprise tool typically handles PV/data protection:

| Product | K8s integration | Strengths |
|---|---|---|
| **Veeam Kasten (K10)** | Dedicated operator + CRDs | Purpose-built for k8s; policy engine, app-consistent hooks, DR to other clusters |
| **Commvault** | Commvault agent/Virtualization protection | One catalog for VMs+containers+DBs; long-term retention/compliance |
| **NetBackup** | NetBackup for Kubernetes | Enterprise dedup/air-gap appliances; broad array integration |
| **Velero/OADP** | Native k8s API objects | Free, GitOps-friendly, no external deps |

**Integration pattern**: enterprise tool owns data/PVs + long retention + cross-site replication; Velero (or just GitOps + etcd snapshots) owns cluster-object restore. Agree the boundary in the RACI — who restores a namespace at 3 AM?

## Part 5 — DR strategy across regions

### 5.1 The two canonical patterns

| | **Active-Passive** | **Active-Active** |
|---|---|---|
| Model | DR site warm/cold standby; failover on disaster | Both regions serve traffic simultaneously |
| Data | Replicated one-way (or restored from backup) | Bi-directional replication — hard for stateful |
| RTO | Minutes–hours (warm) / hours–days (cold) | Near-zero (traffic shifts) |
| RPO | Depends on replication lag | Near-zero |
| Cost | ~1.3–1.5× single site | ≥2× + conflict-resolution complexity |
| Complexity | Moderate — scripted failover runbook | High — global LB, split writes, data conflicts |

### 5.2 DR mechanism tiers — match mechanism to workload tier

| Mechanism | RTO | RPO | Use for |
|---|---|---|---|
| **Backup→restore at DR site** (Velero) | Hours | Last backup (24h) | Tier-2/3 apps — simplest DR |
| **Storage replication** (NFS rsync/snapmirror, Ceph RBD mirroring) | ~1h | Minutes–hours | Important stateful apps |
| **App-level replication** (Postgres streaming, MySQL GTID, Redis replica) | Minutes | Seconds | Critical DBs |
| **Active-active** (geo clusters + global LB) | Near-zero | Near-zero | Only when NFR demands it |

### 5.3 The realistic pattern for this cluster

Single site today — the design target is **active-passive with a second OCP cluster**:

```
Region A (primary) ──GitOps──► Region B (DR)          # same manifests, same state
        │                          ▲
        └── Velero backups ──► replicated S3 bucket ──┘   # restore on failover
        └── DB replication (streaming/binlog) ────────────┘   # tier-1 only
Failover: GSLB/DNS switch + pre-rehearsed runbook
```

### 5.4 Restore-to-different-cluster gotchas

Restoring onto a *different* cluster isn't `velero restore` alone:

| Gotcha | Handling |
|---|---|
| Route hostnames differ per cluster domain | `route.openshift.io` host is stored in the object — plan DNS so `*.apps` works at both sites, or patch routes on restore |
| Cluster CA / service CA differ | Re-issue certs via cert-manager at DR site (Issue 25 makes this automatic) |
| Image registry pull secrets | Copy `pull-secret` or ensure DR cluster trusts the same registry (Issue 17 pattern) |
| PVs provisioned by NFS | Velero restores PVC objects; storage must exist at DR — replicate the NFS export or let nodeAgent write data into fresh volumes |
| etcd/cluster identity | DON'T restore etcd from site A onto site B — restore **workloads**, not cluster state |

## Part 6 — Best practices

### 6.1 Schedule backups off-peak

- Night/low-traffic windows; **stagger** etcd (02:00), DB dumps (01:00), Velero (03:30) — already reflected in the manifests
- Avoid overlap with `etcd` compaction and node maintenance
- nodeAgent fs-backup is I/O-heavy — on NFS it competes with every other workload's storage

### 6.2 Test restores regularly — the drill

A backup never restored is a hypothesis. Monthly drill:

```bash
# 1. Pick a real backup, restore into a copy namespace
oc create -n openshift-adp -f - <<EOF
apiVersion: velero.io/v1
kind: Restore
metadata: {name: drill-$(date +%Y%m)}
spec:
  backupName: <latest-daily>
  namespaceMapping: {<ns>: <ns>-drill}
  restorePVs: true
EOF

# 2. Verify app actually works in the drill ns
oc get pods -n <ns>-drill; curl the route; spot-check data

# 3. Record the drill — date, backup used, result — in this repo as an issue entry
# 4. Clean up
oc delete project <ns>-drill
```

Run `scripts/velero-backup-check.sh` weekly — it flags missing restore evidence.

### 6.3 Replicate across regions

- Object storage replication: S3 bucket replication (MinIO `mc mirror`, Ceph multisite) so backups exist in Region B even if Region A is ash
- Backup location ≠ the cluster it protects — `~/etcd-snapshots` on the admin host is off-node but **on-site**; real DR needs a second site (or cloud bucket)
- Immutability: enable object-lock/versioning on the backup bucket — ransomware that reaches the cluster shouldn't reach the backups

### 6.4 Monitor the backup system itself

- `Backup` objects `PartiallyFailed/Failed` → alert (route to Prometheus/Slack — Issue 16)
- BackupStorageLocation `Unavailable` → alert — silent storage auth expiry is the #1 discovered-too-late failure
- Track restore drill dates — a stale drill is a stale backup

## Part 7 — Implementation runbook (this cluster)

```bash
# 1. Stand up S3 target (MinIO in velero-storage ns, NFS-backed) — Part 2.1
# 2. Install OADP + DPA
oc apply -f manifests/oadp-install.yaml
oc create secret generic cloud-credentials -n openshift-adp --from-file=cloud=credentials-velero
oc apply -f manifests/dpa-velero.yaml
# 3. Deploy DB dump CronJobs for each DB namespace
oc apply -f manifests/db-backup-cronjob.yaml
# 4. Schedules
oc apply -f manifests/backup-schedules.yaml
# 5. Prove it — ad-hoc backup of one app, then namespaceMapping restore drill
# 6. Weekly: ./scripts/velero-backup-check.sh
```

## Part 8 — Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| BackupStorageLocation `Unavailable` | Bad creds/endpoint/TLS | `oc logs deploy/velero -n openshift-adp`; check `s3Url`, `s3ForcePathStyle`, CA |
| Backup `PartiallyFailed` on PVs | nodeAgent can't mount/read volume | `oc logs -n openshift-adp -l name=node-agent`; check podSecurity on the workload ns |
| Restored pods `ImagePullBackOff` | pull-secret/registry unreachable at DR | Copy pull-secret; trust registry CA |
| Restored PVCs `Pending` | StorageClass missing at target | Create SC or add `pvc`/`pv` to `excludedResources` and pre-provision |
| DB restore corrupt/won't start | Crash-inconsistent volume backup | Use logical dump (Part 3.3) — this is why it exists |
| Backups silently stopped | Schedule deleted / velero scaled to 0 / bucket full | `velero-backup-check.sh`; alert on BSL status |

---

## Decision recap

```
Cluster state?        → etcd snapshot (Issue 27) — already covered
App objects + PVs?    → Velero/OADP + nodeAgent (NFS has no CSI snapshots)
Databases?            → logical dump CronJob + fs-backup hooks — never volume-only
Enterprise backup?    → Commvault/Kasten/NetBackup owns data plane; Velero owns objects
Second region?        → active-passive: GitOps parity + replicated S3 + DB streaming for tier-1
Non-negotiables       → off-peak windows, monthly restore drill, off-site replication
```
