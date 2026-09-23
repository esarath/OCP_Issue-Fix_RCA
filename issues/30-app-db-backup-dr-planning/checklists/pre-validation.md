# Pre-Validation Checklist — Backup/Restore & DR Implementation

Run BEFORE deploying OADP/schedules and BEFORE declaring DR capability. Every `[ ]` must become `[x]` or a documented exception — no silent skips.

> Placeholders in `<angle brackets>` — replace before running.

---

## A. Requirements & scope (Day-0 inputs confirmed)

- [ ] Workload tier table exists — every namespace/app classified Critical/Important/Standard with RPO + RTO (Guide Part 1)
- [ ] RPO/RTO numbers **agreed in writing** by the customer/business owner — not assumed
- [ ] Scope list: which namespaces, PVs, and databases are in/out — written down
- [ ] Backup window agreed with app teams (off-peak; no conflict with etcd 02:00, dumps 01:00, Velero 03:30)
- [ ] Retention policy defined per tier (e.g. daily 30d / 6h critical 14d)
- [ ] DR target chosen: active-passive vs active-active — decision recorded (ADR per Issue 29)

## B. Environment readiness

- [ ] Cluster healthy baseline: `oc get nodes` all Ready; `oc get clusteroperators` all Available/!Degraded
- [ ] etcd backup already working and verified (Issue 27) — `~/etcd-snapshots/` has a tested snapshot
- [ ] S3-compatible target reachable **from the cluster network**: `curl -k https://<s3-endpoint>` from a debug pod or node
- [ ] Bucket exists, versioning/object-lock decided, capacity ≥ 30 days of backups (estimate: `sum of PVC sizes` × retention × ~1.2 churn factor)
- [ ] Credentials created and tested against the bucket (`mc ls` / `aws s3 ls` with the keypair)
- [ ] NFS provisioner healthy — `oc get pods -n nfs-provisioner`; PVs Bound for workloads to be backed up
- [ ] Clock sync on all nodes (NTP) — backup timestamps and TLS depend on it: `timedatectl` on masters/workers

## C. OADP install validation

- [ ] `oc get subscription redhat-oadp-operator -n openshift-adp` → install succeeded, correct channel
- [ ] `cloud-credentials` secret exists in `openshift-adp` — key `cloud`, no password committed to git
- [ ] `DataProtectionApplication` `velero-dpa` reconciled — `oc get dpa -n openshift-adp`
- [ ] Velero pods Running: `oc get pods -n openshift-adp` (velero + node-agent DaemonSet = one per node)
- [ ] `BackupStorageLocation` phase **Available**: `oc get backupstoragelocation -n openshift-adp`
- [ ] `dpa-velero.yaml` reviewed: `nodeAgent.enable: true` (NFS has no CSI snapshotter), `s3ForcePathStyle` correct for the endpoint, `insecureSkipTLSVerify` NOT true in prod

## D. Database-specific pre-checks

- [ ] Each DB has a logical-dump CronJob planned/deployed (Guide Part 3.3)
- [ ] Dump PVC created and Bound: `oc get pvc db-dumps -n <db-ns>`
- [ ] `db-backup-creds` secret exists; test dump ran once manually:
  `oc create job --from=cronjob/postgres-logical-backup test-dump -n <db-ns>` → logs show a non-empty `.sql.gz`
- [ ] Velero pre/post hooks decided per DB engine (Postgres `pg_backup_start/stop`, MySQL `FLUSH TABLES WITH READ LOCK`, Mongo `fsyncLock`, Redis `BGSAVE`)
- [ ] Dump file lands on a PV that IS included in Velero backups

## E. DR design pre-checks (if second region/cluster in scope)

- [ ] DR cluster reachable and sized to accept restored workloads
- [ ] DNS/failover method decided (GSLB, DNS TTL switch, manual) — owner assigned
- [ ] Backup bucket replicated to DR region (S3 replication / `mc mirror` scheduled)
- [ ] Route hostname strategy for DR site documented (same `*.apps` domain or patched on restore)
- [ ] Pull secrets / registry trust planned at DR site
- [ ] Failover runbook exists — steps, order, decision authority, rollback trigger

---

## Sign-off

| Role | Name | Date | Signature |
|---|---|---|---|
| Platform lead | | | |
| App owner | | | |
| Business owner (RPO/RTO) | | | |
