# etcd Backup, Restore & Control-Plane Crash Recovery — Full Runbook

Detailed procedures for the lab cluster (OCP 4.20.35, 3 masters + 2 workers, UPI/Proxmox). Covers: taking backups, automating them, verifying them, and recovering from every etcd failure mode — single dead member through total quorum loss.

> **Placeholder convention** (repo-wide): anything in `<angle brackets>` is a placeholder — replace the whole token before running.

---

## Table of Contents

1. [Concepts — how etcd runs on OCP](#part-0--concepts--how-etcd-runs-on-ocp)
2. [Requirements](#part-1--requirements)
3. [On-demand backup](#part-2--on-demand-backup)
4. [Automated backups + retention](#part-3--automated-backups--retention)
5. [Verifying a backup](#part-4--verifying-a-backup)
6. [Scenario A — single etcd member down, quorum intact](#part-5--scenario-a--single-etcd-member-down-quorum-intact)
7. [Scenario B — quorum lost / full restore to a previous state](#part-6--scenario-b--quorum-lost--full-restore)
8. [Scenario C — complete control-plane loss](#part-7--scenario-c--complete-control-plane-loss)
9. [Post-restore validation checklist](#part-8--post-restore-validation-checklist)
10. [Troubleshooting](#part-9--troubleshooting)
11. [Ongoing care — defrag, compaction, disk alarms](#part-10--ongoing-care)

---

## Part 0 — Concepts: how etcd runs on OCP

| Fact | Why it matters for backup/restore |
|---|---|
| etcd runs as **static pods** (`etcd-<node>` in `openshift-etcd`), started by kubelet from `/etc/kubernetes/manifests` — not by the API | You can restore etcd even when the API is completely dead |
| The **cluster-etcd-operator** manages membership, certs, and config | Single-member failures heal mostly automatically; don't fight it with manual `etcdctl member add` |
| Data lives at `/var/lib/etcd/member` on each master | A corrupted/deleted member dir is the most common single-node failure |
| **Quorum = floor(n/2)+1**. 3 members → tolerate 1 failure. 2 failures → cluster is read-only/dead | 2+ masters down = restore-from-snapshot territory |
| Control plane static pods (kube-apiserver, kube-controller-manager, kube-scheduler, etcd) get their config/certs from `/etc/kubernetes/static-pod-resources` | That's why a backup is TWO artifacts: the DB snapshot **and** the resources tarball |

### What `cluster-backup.sh` produces

| File | Contents | Needed for |
|---|---|---|
| `snapshot_<ts>.db` | Point-in-time etcd database — every API object, secret, configmap | Restoring cluster state |
| `static_kuberesources_<ts>.tar.gz` | `/etc/kubernetes/static-pod-resources` — certs, config for all static pods | Restoring masters so the snapshot's certs/secrets actually match |

**They are a matched pair.** A snapshot restored without its resources tarball leaves static pods presenting wrong/mismatched certs — the classic cause of a "restored but API still won't come up" failure.

---

## Part 1 — Requirements

| Requirement | Value on this cluster | Verify |
|---|---|---|
| SSH to all masters | `ssh -i ~/.ssh/ocp4-key core@192.168.29.21/.22/.23` | `ssh ... 'hostname'` |
| Cluster-admin kubeconfig | `~/ocp/install/auth/kubeconfig` (system:admin, cert-based — works even when OAuth is broken) | `oc whoami` |
| `oc` client matching cluster | 4.20.x | `oc version` |
| Backup destination | `~/etcd-snapshots/` on this host — **off-node** | A backup left on the master it protects is not a backup |
| Disk space | Snapshot ≈ etcd DB size (`etcdctl endpoint status` → DB SIZE, typically 100–500 MB) + ~50 MB resources | `df -h` both sides |
| Time | Snapshot: <1 min. Full restore: 15–45 min depending on cluster size | — |
| Downtime expectation | Backup: none. Full restore: **API down** during the procedure | Plan a window |

---

## Part 2 — On-demand backup

The supported method — `cluster-backup.sh` exists on every master at `/usr/local/bin/cluster-backup.sh`. It takes a consistent snapshot **and** tars the static pod resources in one shot.

### 2.1 Pick a healthy master and take the backup

```bash
export KUBECONFIG=~/ocp/install/auth/kubeconfig

# Any one master — etcd members hold identical data; one snapshot is enough
ssh -i ~/.ssh/ocp4-key core@192.168.29.21 \
  'sudo /usr/local/bin/cluster-backup.sh /home/core/assets/backup'
```

Alternative without SSH (runs a debug pod on the node):

```bash
oc debug node/<master-name> -- chroot /host /usr/local/bin/cluster-backup.sh /host/home/core/assets/backup
```

### 2.2 Confirm what was produced

```bash
ssh -i ~/.ssh/ocp4-key core@192.168.29.21 'ls -lh /home/core/assets/backup/'
```

Expected:

```
snapshot_2026-09-23_120000.db               # the etcd database
static_kuberesources_2026-09-23_120000.tar.gz
```

### 2.3 Pull it off the node — immediately

```bash
mkdir -p ~/etcd-snapshots/$(date +%Y%m%d)
scp -i ~/.ssh/ocp4-key -r core@192.168.29.21:/home/core/assets/backup/. \
  ~/etcd-snapshots/$(date +%Y%m%d)/
```

Or just run `scripts/etcd-backup.sh` — it does all three steps and applies retention.

### 2.4 (Optional) snapshot-only path

For a quick "state capture" without static pod resources — e.g. before a risky config change where you only need data:

```bash
oc -n openshift-etcd exec etcd-<pod> -c etcdctl -- \
  etcdctl snapshot save /var/lib/etcd/snapshot.db
oc -n openshift-etcd cp etcd-<pod>:/var/lib/etcd/snapshot.db \
  ~/etcd-snapshots/snapshot-$(date +%Y%m%d).db -c etcdctl
```

> This alone is **not** sufficient for control-plane restore — no static pod resources. Use `cluster-backup.sh` for DR-grade backups.

---

## Part 3 — Automated backups + retention

### Option 1 (recommended here) — host cron + `etcd-backup.sh`

```bash
chmod +x scripts/etcd-backup.sh
crontab -e
```

```cron
# Daily 02:00 — snapshot on master-1, pull to ~/etcd-snapshots, keep last 7
0 2 * * * /home/centos/OCP_Issue-Fix_RCA/issues/27-etcd-backup-restore-crash-recovery/scripts/etcd-backup.sh >> /home/centos/etcd-snapshots/backup.log 2>&1
```

Prereq: passwordless SSH (the `ocp4-key` already is) and sudo on masters without a TTY password — verify once: `ssh -i ~/.ssh/ocp4-key core@192.168.29.21 'sudo -n true'`.

### Option 2 — in-cluster CronJob

`manifests/etcd-backup-cronjob.yaml` — runs `oc debug node` + `cluster-backup.sh` on a schedule. Caveats: needs a `cluster-admin` SA (for `oc debug node`), and files still land on the node's disk — you must pull them off-box for real DR. Host cron is simpler; this exists for environments where SSH is disallowed.

### Retention policy

| Keep | Rationale |
|---|---|
| Last 7 daily | Covers the "someone broke it last week" window |
| 1 per month, 3 months | Longer-horizon rollback |
| A copy before every upgrade/major change | Point-in-time anchored to the event — `etcd-backup.sh` run manually |

> Snapshots contain **all secrets in plaintext**. Restrict `~/etcd-snapshots` (`chmod 700`), and if copying elsewhere, encrypt (`gpg -c`) or use an encrypted filesystem.

---

## Part 4 — Verifying a backup

A backup you haven't verified is a hope, not a backup.

```bash
# Inside an etcd container (has etcdctl + matching version):
oc -n openshift-etcd cp ~/etcd-snapshots/<ts>/snapshot_<ts>.db \
  etcd-<pod>:/tmp/verify.db -c etcdctl
oc -n openshift-etcd exec etcd-<pod> -c etcdctl -- \
  etcdctl snapshot status /tmp/verify.db -w table
```

Healthy output — nonzero hash, member count matches:

```
+---------+----------+------------+------------+---------+
|  HASH   | REVISION | TOTAL KEYS | TOTAL SIZE | MEMBERS |
+---------+----------+------------+------------+---------+
| a1b2c3d |  1234567 |     12450  |   145 MB   |    3    |
+---------+----------+------------+------------+---------+
```

Also sanity-check the tarball:

```bash
tar -tzf ~/etcd-snapshots/<ts>/static_kuberesources_<ts>.tar.gz | head
# expect: static-pod-resources/etcd-pod-*/..., kube-apiserver-pod-*/..., secrets/..., configmaps/...
```

---

## Part 5 — Scenario A: single etcd member down, quorum intact

**Symptoms**: `oc get pods -n openshift-etcd` shows one `etcd-<node>` CrashLooping/not-ready; `oc adm top nodes`/`oc get nodes` may still work; `etcdctl endpoint health --cluster` shows 2/3 healthy. **API stays up — you have quorum.**

### 5.1 Confirm it's etcd, not the node

```bash
./scripts/etcd-health-check.sh
oc -n openshift-etcd logs etcd-<bad-node> -c etcd --tail=50
oc describe node <bad-node> | grep -A5 Conditions
```

Common causes: corrupted `/var/lib/etcd/member` (unclean shutdown), disk full, cert expiry.

### 5.2 Check the operator is healthy first

```bash
oc get clusteroperator etcd
oc -n openshift-etcd-operator logs deploy/etcd-operator --tail=50
```

If the operator itself is degraded, fix that first — it orchestrates the repair.

### 5.3 Remove the dead member

```bash
# From a healthy member — get the dead member's ID
oc -n openshift-etcd exec etcd-<healthy-pod> -c etcdctl -- \
  etcdctl member list -w table

oc -n openshift-etcd exec etcd-<healthy-pod> -c etcdctl -- \
  etcdctl member remove <dead-member-id>
```

### 5.4 Clear the member's certs + data so it rejoins clean

```bash
# Delete the per-member cert secrets — operator regenerates them
oc -n openshift-etcd delete secret \
  etcd-peer-<bad-node> etcd-serving-<bad-node> etcd-serving-metrics-<bad-node>

# On the node — wipe the corrupt data dir
ssh -i ~/.ssh/ocp4-key core@<bad-node> \
  'sudo rm -rf /var/lib/etcd/member'

# Kill the pod — kubelet/operator rebuild it as a fresh member
oc -n openshift-etcd delete pod etcd-<bad-node>
```

### 5.5 Watch it rejoin

```bash
oc -n openshift-etcd get pods -w                      # etcd-<node> restarts
oc -n openshift-etcd exec etcd-<healthy> -c etcdctl -- etcdctl member list -w table
oc -n openshift-etcd exec etcd-<healthy> -c etcdctl -- etcdctl endpoint health --cluster -w table
```

Expect the member back in `member list` (new ID is fine) and 3/3 healthy within a few minutes. The operator drives rejoin — if it stalls >10 min, check `etcd-operator` logs and `oc get etcd cluster -o yaml` conditions.

> **Do NOT** manually `etcdctl member add` on OCP — membership is the operator's job. Manual adds create a split state the operator then has to untangle.

---

## Part 6 — Scenario B: quorum lost / full restore

**Symptoms**: 2+ masters down or etcd corrupted; API unresponsive (`oc` commands hang/timeout); console dead. OR: you deliberately need to roll the whole cluster back to a snapshot (bad upgrade, mass deletion).

This is the official **"restore to a previous cluster state"** procedure — `cluster-restore.sh` reconstitutes etcd from the snapshot on every master.

### 6.1 Requirements checklist — confirm ALL before starting

| # | Requirement |
|---|---|
| 1 | A backup pair from the **same run**: `snapshot_<ts>.db` + `static_kuberesources_<ts>.tar.gz` |
| 2 | SSH (sudo-capable) to **every** control plane host |
| 3 | All masters powered on / VMs running — restore needs all of them to reform quorum |
| 4 | Installer kubeconfig available for post-restore verification |
| 5 | Maintenance window: **API is DOWN for the whole procedure** |

### 6.2 Distribute the backup pair to every master

```bash
for m in 192.168.29.21 192.168.29.22 192.168.29.23; do
  ssh -i ~/.ssh/ocp4-key core@$m 'mkdir -p /home/core/assets/backup'
  scp -i ~/.ssh/ocp4-key \
    ~/etcd-snapshots/<ts>/snapshot_<ts>.db \
    ~/etcd-snapshots/<ts>/static_kuberesources_<ts>.tar.gz \
    core@$m:/home/core/assets/backup/
done
```

### 6.3 Run the restore script on EVERY master

```bash
for m in 192.168.29.21 192.168.29.22 192.168.29.23; do
  echo "=== restoring on $m ==="
  ssh -i ~/.ssh/ocp4-key core@$m \
    'sudo /usr/local/bin/cluster-restore.sh /home/core/assets/backup'
done
```

What the script does on each node (so you know what "normal" looks like):

1. Moves `/etc/kubernetes/manifests` static pod manifests aside — kube-apiserver, etcd, scheduler, controller-manager all stop (expected; the API is already down anyway)
2. Extracts `static_kuberesources_<ts>.tar.gz` into `/etc/kubernetes/static-pod-resources` — restores the certs/configs that match the snapshot
3. Writes a restore manifest so etcd starts with `--initial-cluster-state` rebuilt **from the snapshot**, reforming a fresh cluster (new cluster ID, same data)
4. kubelet brings etcd up; when all three nodes have done this, quorum re-forms and the remaining static pods resume

> If a node fails mid-script, its manifests are parked under a sibling dir (script echoes the path — typically `/etc/kubernetes/manifests-stopped`). Copying them back restores the pre-restore state for debugging.

### 6.4 Watch etcd reform

```bash
# On any master
ssh -i ~/.ssh/ocp4-key core@192.168.29.21 'sudo crictl ps | grep etcd'
ssh -i ~/.ssh/ocp4-key core@192.168.29.21 \
  'sudo crictl logs $(sudo crictl ps --name etcd -q | head -1) 2>/dev/null | tail -30'
```

Look for `ready to serve client requests` / `published the cluster membership`. Once all three report members, the API starts responding.

### 6.5 Verify the API is back

```bash
export KUBECONFIG=~/ocp/install/auth/kubeconfig
oc get nodes                          # all 5 should appear; masters may start NotReady
oc -n openshift-etcd get pods -o wide # etcd-<m1/m2/m3> Running
./scripts/etcd-health-check.sh        # 3 members, 3/3 healthy, no alarms
```

### 6.6 Approve pending CSRs

After a restore, node kubelet serving CSRs often sit pending:

```bash
oc get csr | grep -i pending
oc get csr -o name | xargs -r oc adm certificate approve   # or approve selectively
oc get nodes    # wait for all Ready
```

### 6.7 Let the control plane settle

```bash
oc adm wait-for-stable-cluster          # waits for operators to stop progressing
oc get clusteroperators                 # all AVAILABLE=True, DEGRADED=False
oc get pods -A | grep -v Running\|Completed   # anything stuck?
```

**What comes back / what doesn't**: the cluster state returns to the snapshot instant — everything created after the backup is gone (namespaces, secrets, workloads). Longer-lived infrastructure (nodes, PVs on NFS) is unaffected.

---

## Part 7 — Scenario C: complete control-plane loss

All 3 masters destroyed (Proxmox storage failure, etc.):

1. Rebuild 3 masters (same hostnames/IPs strongly preferred — etcd peer URLs and certs encode them)
2. If IPs/hostnames are identical → Part 6 verbatim: push the backup pair, run `cluster-restore.sh` on each
3. If hostnames/IPs **changed** → snapshot data is still valid but static pod resources reference old names; expect additional cert/config surgery — escalate rather than improvise
4. Workers rejoin after masters are healthy; approve their CSRs (Part 6.6)

---

## Part 8 — Post-restore validation checklist

```bash
export KUBECONFIG=~/ocp/install/auth/kubeconfig

oc get nodes                                       # 5/5 Ready
oc get clusteroperators                            # all Available, none Degraded
oc get etcd cluster -o yaml | grep -A20 conditions # operator happy
./scripts/etcd-health-check.sh                     # 3 members healthy, 0 alarms
oc get csr                                         # none pending
oc get pods -A | grep -v 'Running\|Completed'      # clean
oc get routes -A | head                            # ingress back
curl -k https://api.lab.ocp.local:6443/healthz     # ok
# Spot-check app data that post-dates the snapshot is EXPECTED GONE
oc get projects
```

Then take a **fresh backup immediately** — you've just used your safety net:

```bash
./scripts/etcd-backup.sh
```

---

## Part 9 — Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `cluster-backup.sh: command not found` | Not in `/usr/local/bin` via chroot — ran outside host ns | Use `ssh core@<master> 'sudo /usr/local/bin/cluster-backup.sh ...'` or `oc debug node -- chroot /host ...` |
| Snapshot `status` fails / garbage | Corrupt copy or truncated download | Re-scp; compare sizes on node vs local |
| After restore, etcd never forms quorum | Mixed snapshot+resources from different backups; or a master didn't run restore | Re-run with a matched pair on ALL masters; check `crictl logs` for `cluster ID mismatch` |
| API up but all kubelets Unauthorized | CSR approval skipped | Part 6.6 |
| `etcdctl: context deadline exceeded` on member list | That member is dead — exec into a different pod | Use another `etcd-<pod>`; commands must run on a live member |
| `mv: cannot move /etc/kubernetes/manifests` during restore | Script already ran / leftover manifests-stopped dir | Check for `/etc/kubernetes/manifests-stopped`; don't re-run blindly — inspect state first |
| Member keeps crash-looping after rejoin | Old data dir not fully wiped | Confirm `/var/lib/etcd/member` removed; check `du -sh /var/lib/etcd` |
| `etcdserver: mvcc: database space exceeded` alarm | DB over quota (defrag needed) | Part 10 — alarm disarm requires defrag, not just compaction |

---

## Part 10 — Ongoing care

```bash
# DB size + fragmentation (run on leader or check each endpoint)
oc -n openshift-etcd exec etcd-<pod> -c etcdctl -- \
  etcdctl endpoint status --cluster -w table

# Manual defrag if DB SIZE >> actual data (only if FRAGMENTED % is high;
# OCP defrags automatically — manual defrag is a last resort, run per-member,
# follower-first, NEVER during high load)
oc -n openshift-etcd exec etcd-<pod> -c etcdctl -- etcdctl defrag

# Clear a NOSPACE alarm after defrag
oc -n openshift-etcd exec etcd-<pod> -c etcdctl -- etcdctl alarm disarm
```

OCP handles compaction automatically; your job is: **snapshots daily, verify monthly, keep masters' `/var/lib/etcd` disks healthy.**

---

## Decision recap

```
1 etcd member dead, API works?  → Scenario A: member remove + wipe + rejoin (operator-driven)
2+ masters dead / API dead?     → Scenario B: cluster-restore.sh with snapshot+resources on ALL masters
All masters gone?               → Scenario C: rebuild nodes (same names/IPs), then Scenario B
Just want insurance?            → Part 2 now, Part 3 forever, Part 4 monthly
```
