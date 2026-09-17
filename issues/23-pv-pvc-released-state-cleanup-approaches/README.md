# Issue 23 — PV/PVC Released-State Cleanup: All Approaches & Storage Claim Scenarios

| Field | Detail |
|---|---|
| **Date** | 2026-09-17 |
| **Type** | Technical Analysis & Cleanup Guide |
| **Status** | Completed — 12 Released PVs (54Gi) deleted; 6 Bound PVs remain; NFS server-side dir cleanup is a manual step |
| **Scope** | All PV/PVC claim scenarios, every cleanup approach, and the live fix applied to the cluster |
| **Cluster** | lab.ocp.local (OCP 4.20.35, dev/testing environment) |
| **Problem** | 12 PersistentVolumes stuck in `Released` state — 54Gi of orphaned storage on the NFS server after PVCs were deleted |
| **Solution Applied** | Batch deletion of all Released PVs (Approach 2); StorageClass `Retain` policy left unchanged |

---

## Problem Context

**Storage status before cleanup:**

- **Total PVs**: 18 (170Gi capacity)
- **Bound PVs**: 6 (~152Gi actively in use)
- **Released PVs**: 12 (54Gi orphaned — deleted PVCs left behind retained volumes)

**Released PVs found:**

| PV Name | Capacity | Original Claim (ns/name) | Age | Application |
|---------|----------|--------------------------|-----|-------------|
| `pvc-0309c35e-…-0a82d419d6eb` | 4Gi | car-rental-prod/ollama-models | 12d | Car Rental ML Models |
| `pvc-0a5b6863-…-100f36b9c072` | 4Gi | car-rental-prod/ollama-models | 7d | Car Rental ML Models |
| `pvc-0a977467-…-c726e2467e3b` | 4Gi | car-rental-dev/ollama-models | 13d | Car Rental ML Models |
| `pvc-dd304e63-…-6bbf9616941c` | 4Gi | car-rental-dev/ollama-models | 7d | Car Rental ML Models |
| `pvc-e9b6a597-…-e03568ba021b` | 4Gi | car-rental-prod/ollama-models | 13d | Car Rental ML Models |
| `pvc-62a1f85c-…-a2cac1135dd4` | 2Gi | car-rental-dev/data-postgresql-0 | 13d | Car Rental Dev DB |
| `pvc-812d8a15-…-58179b266863` | 2Gi | car-rental-prod/data-postgresql-0 | 12d | Car Rental Prod DB |
| `pvc-a1c58526-…-5af15c6c4836` | 2Gi | car-rental-prod/data-postgresql-0 | 13d | Car Rental Prod DB |
| `pvc-88cc779b-…-de77cff641fb` | 10Gi | redis-platform/data-redis-db-0 | 19d | Redis Platform |
| `pvc-c081a1ff-…-b01c-c726e2467e3b` | 10Gi | redis-platform/data-redis-db-1 | 19d | Redis Platform |
| `pvc-202d028f-…-988f-e3c9ae80b06d` | 2Gi | stage/data-redis-db-0 | 16d | Stage Redis |
| `pvc-fca50bda-…-9e62-c7c28cdbaecf` | 1Gi | db/db-pvc | 11d | General DB |

**Storage configuration on this cluster:**

| Component | Value |
|---|---|
| StorageClass | `nfs-storage` (default) |
| Provisioner | `nfs-storage` (deployment `nfs-client-provisioner` in `nfs-provisioner` ns) |
| Reclaim Policy | `Retain` ← **root cause of the accumulation** |
| Volume Binding | `Immediate` |
| NFS Server | `192.168.29.10` |
| Export Path | `/var/nfs/dynamic/` |
| Dir naming | `<namespace>-<pvc-name>-<pv-name>` (e.g. `car-rental-prod-ollama-models-pvc-0309c35e-…`) |
| PV finalizer | `kubernetes.io/pv-protection` |

---

## Storage Concepts: PV / PVC / StorageClass

### The Three Objects

```
PersistentVolumeClaim (PVC)          PersistentVolume (PV)          StorageClass (SC)
  "I want 4Gi RWO storage"     →      "I am 4Gi of NFS storage"       "How to make PVs"
        namespaced                    cluster-scoped                  cluster-scoped
```

- **PV (PersistentVolume)**: A piece of actual storage in the cluster — an NFS export, an iSCSI LUN, a cloud disk. Cluster-scoped, exists independently of any pod.
- **PVC (PersistentVolumeClaim)**: A namespace-scoped *request* for storage. A pod mounts a PVC, never a PV directly. The PVC binds to exactly one PV that satisfies its size, access mode, and StorageClass.
- **StorageClass**: The template used for **dynamic provisioning**. When a PVC references a StorageClass, the provisioner creates a matching PV (and the backing storage) automatically. No StorageClass → the PVC can only bind to a pre-existing static PV.

### Dynamic Provisioning Flow (our cluster)

```
1. User creates PVC (storageClassName: nfs-storage)
2. nfs-client-provisioner pod sees the PVC
3. Creates dir on NFS server: /var/nfs/dynamic/<ns>-<pvc>-<pv-uuid>
4. Creates PV object pointing at that dir
5. Kubernetes binds PVC ↔ PV (status: Bound)
```

### Access Modes

| Mode | Meaning | NFS support |
|---|---|---|
| `RWO` (ReadWriteOnce) | Mountable read-write by a single node | ✅ |
| `RWX` (ReadWriteMany) | Mountable read-write by many nodes simultaneously | ✅ (native NFS strength) |
| `ROX` (ReadOnlyMany) | Mountable read-only by many nodes | ✅ |

### Reclaim Policies — what happens to a PV when its PVC is deleted

| Policy | PV behavior | Backend data | Notes |
|---|---|---|---|
| `Retain` | PV stays, goes `Released` | **Preserved** — manual cleanup required | Our StorageClass setting; why Released PVs piled up |
| `Delete` | PV object deleted | **Deleted** by the provisioner (if supported) | Convenient for dev; dangerous for prod data |
| `Recycle` | *(deprecated)* | Basic scrub + Available again | Removed in modern Kubernetes — do not use |

### PV Lifecycle Phases

```
Available ──(PVC created)──→ Bound ──(PVC deleted)──→ Released ──(admin action)──→ Available or gone
                                                              ↘ Failed (reclaim error)
```

| Phase | Meaning | Action needed |
|---|---|---|
| `Available` | Free, unclaimed, ready to bind | None |
| `Bound` | Bound to a PVC | None — healthy state |
| `Released` | Its PVC was deleted, but `Retain` keeps the PV + data. **Cannot rebind** until claimRef is cleared or PV deleted | Clean up or reclaim (this issue) |
| `Failed` | Automatic reclamation failed | Investigate events, then manual cleanup |

### PVC Phases

| Phase | Meaning |
|---|---|
| `Pending` | No PV bound yet — provisioning in progress or failing |
| `Bound` | Bound to a PV — healthy |
| `Lost` | Its bound PV was deleted/lost — claim is broken |

### Protection Finalizers

| Finalizer | On | Purpose |
|---|---|---|
| `kubernetes.io/pv-protection` | PV | Prevents deleting a PV that is still `Bound` to a PVC |
| `kubernetes.io/pvc-protection` | PVC | Prevents deleting a PVC that is still mounted by a pod |

Deleting a Released PV normally **does not** require touching finalizers — the PV protection controller removes the finalizer itself once the PV is unbound. Stripping finalizers manually is only needed when a PV/PVC is **stuck in `Terminating`**.

---

## All Claim Scenarios & Their Fixes

### Scenario A — PVC stuck `Pending`

**Symptoms**: PVC never binds; pod stays `Pending` / `ContainerCreating` with `FailedMount` or `unbound immediate PersistentVolumeClaims` events.

**Common causes:**

| Cause | Check | Fix |
|---|---|---|
| Provisioner down | `oc get pods -n nfs-provisioner` | Restart/fix provisioner deployment |
| No matching PV (static) | `oc get pv` for size/accessmode/SC match | Create a compatible PV |
| `WaitForFirstConsumer` binding | SC `volumeBindingMode` | Normal — binds when pod is scheduled |
| Resource quota exceeded | `oc describe resourcequota -n <ns>` | Raise quota or free claims |
| Nonexistent StorageClass | `oc get sc <name>` | Fix `storageClassName` on the PVC |

```bash
oc describe pvc <name> -n <ns>        # Events section tells you why
oc get pods -n nfs-provisioner         # Provisioner health
```

### Scenario B — PV in `Released` state (this issue)

**Symptoms**: `oc get pv` shows `Released`; the original claim (`.spec.claimRef`) points to a deleted PVC. Space is still consumed on the NFS server.

**Cause**: StorageClass `reclaimPolicy: Retain` — by design, data is preserved for an admin to inspect before disposal.

**Fixes**: All cleanup Approaches 1–7 below apply. Two paths:

1. **Dispose** — delete the PV + backend data (Approaches 1–6)
2. **Reclaim for reuse** — keep data, make PV `Available` again (Approach 7)

### Scenario C — PV in `Failed` state

**Symptoms**: `oc get pv` shows `Failed`; reclaim error.

**Cause**: The provisioner tried to delete/reclaim backend storage and failed (server unreachable, export gone, permission denied).

**Fix:**

```bash
oc describe pv <pv>                    # Look at Message/Events for the failure reason
# Fix the backend problem first (NFS export exists? server reachable? perms?)
oc delete pv <pv>                      # Then delete the object
# If stuck in Terminating → strip finalizer (Scenario E)
```

### Scenario D — PVC stuck `Terminating`

**Symptoms**: PVC shows `Terminating` for a long time; namespace deletion hangs.

**Cause**: `kubernetes.io/pvc-protection` finalizer — a pod still references the PVC (even a `Terminating`/`Failed` pod).

**Fix:**

```bash
# 1. Find pods still using it
oc get pods -n <ns> -o json | jq -r '.items[] | select(.spec.volumes[]?.persistentVolumeClaim.claimName=="<pvc>") | .metadata.name'

# 2. Delete/force-delete those pods
oc delete pod <pod> -n <ns> --force --grace-period=0

# 3. Only if still stuck — force-remove the finalizer
oc patch pvc <pvc> -n <ns> -p '{"metadata":{"finalizers":null}}'
```

### Scenario E — PV stuck `Terminating`

**Symptoms**: `oc delete pv` runs but PV remains with `deletionTimestamp` set.

**Cause**: `kubernetes.io/pv-protection` finalizer held because Kubernetes thinks the PV is still bound (claimRef points at a PVC object that still exists), or the protection controller hasn't reconciled.

**Fix:**

```bash
# 1. Check what it thinks it is bound to
oc get pv <pv> -o jsonpath='{.spec.claimRef}'

# 2. If the referenced PVC still exists, delete it first
oc delete pvc <name> -n <ns>

# 3. Force-remove the finalizer (safe only for Released/Failed PVs)
oc patch pv <pv> -p '{"metadata":{"finalizers":null}}'
```

### Scenario F — PVC `Lost` / PV `Bound` to a deleted claim

**Symptoms**: PVC shows `Lost`; or PV shows `Bound` but `oc get pvc` says the claim doesn't exist.

**Cause**: PV was deleted out from under a bound PVC, or a namespace was force-deleted leaving a dangling claimRef.

**Fix:**

```bash
# For a PV Bound to a dead claim — clear the claimRef to make it Available
oc patch pv <pv> --type json -p '[{"op":"remove","path":"/spec/claimRef"}]'

# For a Lost PVC — recreate it; if the PV still exists and claimRef was cleared, it can rebind
```

### Scenario G — Reclaim a `Released` PV for reuse (keep the data)

**Symptoms**: Want the volume's data back in service under a new claim.

```bash
# 1. Clear the old claimRef → PV goes Available
oc patch pv <pv> --type json -p '[{"op":"remove","path":"/spec/claimRef"}]'

# 2. Create a new PVC matching size/accessmode/storageclass → binds to it
oc apply -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: <new-pvc>
  namespace: <ns>
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: nfs-storage
  resources:
    requests:
      storage: 4Gi
EOF
```

> To pin the new PVC to *this specific* PV, add `spec.volumeName: <pv-name>` to the PVC.

---

## All Cleanup Approaches

### Approach 1: Manual Per-PV Deletion (Direct)

**When to use**: A handful of Released PVs; you're certain the data is unneeded.

```bash
# Delete a single Released PV (finalizer removal usually NOT needed)
oc delete pv <pv-name>

# Then remove the backing data on the NFS server
ssh core@192.168.29.10
rm -rf /var/nfs/dynamic/<ns>-<pvc>-<pv-name>
```

| Pros | Cons |
|---|---|
| Immediate, simple, no config changes | Permanent data loss |
| Per-PV control | Manual NFS dir cleanup |
| | Risk of deleting the wrong volume |

### Approach 2: Batch Delete All Released PVs (What We Did Live)

**When to use**: Many Released PVs on a dev/test cluster; bulk reclaim.

```bash
# 1. Review first
oc get pv -o jsonpath='{range .items[?(@.status.phase=="Released")]}{.metadata.name}{"\t"}{.spec.capacity.storage}{"\t"}{.spec.claimRef.namespace}{"\t"}{.spec.claimRef.name}{"\n"}{end}'

# 2. Delete them all
for pv in $(oc get pv -o jsonpath='{.items[?(@.status.phase=="Released")].metadata.name}'); do
  echo "Deleting $pv..."
  oc patch pv "$pv" -p '{"metadata":{"finalizers":null}}'   # belt & braces for stuck ones
  oc delete pv "$pv"
done

# 3. Remove backing dirs on the NFS server
ssh core@192.168.29.10
cd /var/nfs/dynamic/
rm -rf car-rental-prod-ollama-models-* \
       car-rental-dev-ollama-models-* \
       car-rental-dev-data-postgresql-0-* \
       car-rental-prod-data-postgresql-0-* \
       redis-platform-data-redis-db-* \
       stage-data-redis-db-0-* \
       db-db-pvc-*
```

| Pros | Cons |
|---|---|
| One loop frees all orphaned space | Irreversible |
| Scriptable, repeatable | Still needs NFS-side cleanup |
| | No per-volume review |

### Approach 3: Backup-Then-Delete (Safest)

**When to use**: Any doubt about the data; prod-adjacent volumes; audit requirements.

```bash
ssh core@192.168.29.10
mkdir -p /var/nfs/backups/$(date +%Y%m%d)

# Back up each released PV's directory
for pv in $(oc get pv -o jsonpath='{.items[?(@.status.phase=="Released")].metadata.name}'); do
  dir=$(oc get pv "$pv" -o jsonpath='{.spec.nfs.path}')
  cp -r "$dir" "/var/nfs/backups/$(date +%Y%m%d)/$(basename "$dir")"
done

# Then delete the PV objects
for pv in $(oc get pv -o jsonpath='{.items[?(@.status.phase=="Released")].metadata.name}'); do
  oc delete pv "$pv"
done

# Original dirs removed only after backup verified
rm -rf /var/nfs/dynamic/<dir-list>
```

| Pros | Cons |
|---|---|
| Recoverable | Needs NFS access + spare capacity |
| Auditable | Extra steps and time |

### Approach 4: Interactive Selective Cleanup

**When to use**: Mixed importance volumes; want a yes/no per PV.

```bash
#!/bin/bash
for pv in $(oc get pv -o jsonpath='{.items[?(@.status.phase=="Released")].metadata.name}'); do
  echo "PV: $pv"
  echo "  Capacity: $(oc get pv "$pv" -o jsonpath='{.spec.capacity.storage}')"
  echo "  Claim:    $(oc get pv "$pv" -o jsonpath='{.spec.claimRef.namespace}/{.spec.claimRef.name}')"
  echo "  Age:      $(oc get pv "$pv" -o jsonpath='{.metadata.creationTimestamp}')"
  read -p "Delete this PV? (yes/no): " a
  if [[ "$a" == "yes" ]]; then
    oc delete pv "$pv" && echo "Deleted $pv"
  else
    echo "Skipped $pv"
  fi
done
```

| Pros | Cons |
|---|---|
| Maximum control | Slow for many PVs |
| Prevents mistakes | Not automatable |

### Approach 5: Application-Grouped Cleanup

**When to use**: Clean one app's volumes while keeping another's (e.g. drop car-rental, keep redis-platform).

```bash
# Filter Released PVs by the claiming namespace
for pv in $(oc get pv -o json | jq -r '.items[] | select(.status.phase=="Released" and .spec.claimRef.namespace=="car-rental-dev") | .metadata.name'); do
  oc delete pv "$pv"
done
```

| Pros | Cons |
|---|---|
| Scoped by app/namespace | Needs knowledge of what's safe |
| | Multiple passes for multiple apps |

### Approach 6: Age-Based Cleanup + CronJob (Automated Maintenance)

**When to use**: Recurring accumulation on dev clusters; want scheduled hygiene.

```bash
DAYS_OLD=7
CUTOFF=$(date -d "$DAYS_OLD days ago" +%Y-%m-%dT%H:%M:%SZ)
for pv in $(oc get pv -o json | jq -r ".items[] | select(.status.phase==\"Released\") | select(.metadata.creationTimestamp < \"$CUTOFF\") | .metadata.name"); do
  oc delete pv "$pv"
done
```

CronJob version — runs nightly, needs an RBAC ServiceAccount with `persistentvolumes` delete:

```yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: released-pv-cleanup
  namespace: default
spec:
  schedule: "0 2 * * *"
  jobTemplate:
    spec:
      template:
        spec:
          serviceAccountName: pv-cleanup-sa
          containers:
          - name: cleanup
            image: quay.io/openshift/origin-cli:latest
            command: ["/bin/bash","-c"]
            args:
            - |
              for pv in $(oc get pv -o jsonpath='{.items[?(@.status.phase=="Released")].metadata.name}'); do
                oc delete pv "$pv" || true
              done
          restartPolicy: OnFailure
```

| Pros | Cons |
|---|---|
| Zero-touch hygiene | Automated deletion risk — restrict by age/labels |
| | RBAC + monitoring needed |
| | NFS dirs still orphaned (provisioner only acts on provisioned PVs with `Delete` policy) |

### Approach 7: Let the Provisioner Delete the Data (reclaimPolicy → `Delete`)

**When to use**: Want the backend directory removed automatically instead of manual `rm -rf` on the NFS server.

Key detail: `nfs-client-provisioner` **does** honor `Delete` — when a provisioned PV is deleted, the provisioner removes (or archives, if `archiveOnDelete: "true"` is set in the SC) the backing directory. To get Released PVs cleaned end-to-end:

```bash
# Flip the released PVs to Delete, then delete the PV objects —
# the provisioner removes the NFS dirs itself
for pv in $(oc get pv -o jsonpath='{.items[?(@.status.phase=="Released")].metadata.name}'); do
  oc patch pv "$pv" -p '{"spec":{"persistentVolumeReclaimPolicy":"Delete"}}'
  oc delete pv "$pv"
done
```

> ⚠️ Check the provisioner's `archiveOnDelete` setting first — if `"true"`, dirs get renamed to `archived-*` instead of deleted, so space is *not* freed.

| Pros | Cons |
|---|---|
| Backend data removed automatically | Only works for provisioner-created PVs |
| No manual NFS session needed | Same data-loss risk |

### Approach 8: Change the Default Policy — StorageClass `Retain` → `Delete` (Prevention)

**When to use**: Stop the accumulation at the source so future PVC deletions auto-clean.

⚠️ **Important correction**: `StorageClass` objects are **immutable** — `oc patch storageclass nfs-storage -p '{"reclaimPolicy":"Delete"}'` fails with `Forbidden`. You must **delete and recreate** the StorageClass:

```bash
oc get sc nfs-storage -o yaml > nfs-storage-sc-backup.yaml

# Edit the backup: reclaimPolicy: Delete, then:
oc delete sc nfs-storage
oc apply -f nfs-storage-sc-backup.yaml
```

Recreating the default SC is brief and safe — in-flight provisioning pauses, bound PVs are unaffected (each PV keeps its own copy of the policy; only *new* PVs inherit the new default).

For a softer middle ground, set `parameters.archiveOnDelete: "true"` on the SC — provisioner reclaims the PV but archives the data dir instead of deleting it.

| Pros | Cons |
|---|---|
| Permanent fix — no more Released pile-up | `Delete` on a shared dev cluster can destroy data a teammate wanted |
| Future PVC deletes are fully automatic | SC is immutable — needs delete/recreate |
| `archiveOnDelete` offers a safe middle ground | |

### NFS Server-Side Cleanup (always required for `Retain`)

Deleting PV objects only removes cluster records — the data under `/var/nfs/dynamic/` persists until removed on the server:

```bash
ssh core@192.168.29.10
ls /var/nfs/dynamic/                      # match against remaining Bound PV dirs
du -sh /var/nfs/dynamic/* | sort -rh      # confirm sizes before deleting
rm -rf /var/nfs/dynamic/<stale-dir>       # only dirs with no live PV
```

> Map a dir to its PV: dir name = `<claim-namespace>-<pvc-name>-<pv-name>`.

---

## Scenario → Approach Decision Matrix

| Scenario | Recommended approach | Why |
|---|---|---|
| Bulk Released PVs on **dev** | Approach 2 (batch delete) + NFS cleanup | Fastest space recovery, data disposable |
| Released PVs on **prod/unknown data** | Approach 3 (backup-then-delete) | Recoverable |
| A few volumes, mixed importance | Approach 4 (interactive) or 5 (by app) | Per-volume control |
| Recurring accumulation | Approach 6 (CronJob) and/or 8 (SC → Delete/archiveOnDelete) | Preventive |
| Want data back in service | Scenario G (clear claimRef) | Reclaim without loss |
| PVC Pending | Scenario A checks (provisioner, quota, SC) | Diagnose before deleting anything |
| Stuck Terminating PV/PVC | Scenarios D/E (pod → finalizer) | Finalizers are symptoms, not the cause |
| Prod with valuable data | **Keep `Retain`** + Approach 3 workflow | Retain exists to protect you |

---

## What We Did Live (Applied Fix)

**Chosen approach**: Approach 2 — batch delete of all 12 Released PVs (dev cluster, data confirmed disposable).

**Result — before:**

```
18 PVs total: 6 Bound (152Gi) + 12 Released (54Gi)
```

**Result — after:**

```
6 PVs, all Bound:
  pvc-00230c2f-…   10Gi  jenkins-install/jenkins-data
  pvc-3248de46-…  100Gi  openshift-image-registry/image-registry-storage
  pvc-21928515-…   20Gi  openshift-monitoring/prometheus-k8s-db-prometheus-k8s-0
  pvc-ef7d0826-…   20Gi  openshift-monitoring/prometheus-k8s-db-prometheus-k8s-1
  pvc-81da1156-…    2Gi  openshift-monitoring/alertmanager-main-db-alertmanager-main-0
  pvc-e4683900-…    2Gi  openshift-monitoring/alertmanager-main-db-alertmanager-main-1
```

- ✅ 12 Released PVs removed — cluster PV view now clean (18 → 6)
- ✅ All remaining PVCs `Bound`; no `Failed`/`Pending`/`Lost` claims
- ⏳ **NFS dir cleanup** — the remaining manual step; stale dirs under `/var/nfs/dynamic/` must be removed on `192.168.29.10` to physically free the 54Gi. (SSH from the bastion currently fails: host key changed after NFS host redeploy — update `known_hosts` and re-run the `rm -rf` list in Approach 2.)
- **StorageClass unchanged**: `nfs-storage` still `Retain`. Deliberate — dev cluster, and `Retain` prevents accidental loss. Revisit Approach 8 if Released PVs accumulate again.

---

## Safety Checklist (run before any cleanup)

```bash
# 1. Confirm the owning namespaces/apps are really gone
oc get ns | grep -E 'car-rental|redis-platform|stage|db'

# 2. Confirm no pod still mounts the volume
oc get pods -A -o json | jq -r '.items[] | select(.spec.volumes[]?.persistentVolumeClaim.claimName=="<pvc>") | "\(.metadata.namespace)/\(.metadata.name)"'

# 3. Snapshot the PV inventory first
oc get pv -o yaml > pv-inventory-$(date +%Y%m%d).yaml

# 4. Test on ONE pv before batch runs
oc delete pv <one-released-pv>
```

**Rules of thumb:**

1. `Released` ≠ free space — the NFS dir still holds data until deleted server-side or by the provisioner.
2. Never strip finalizers on a `Bound` PV or an in-use PVC — that's how you orphan live data.
3. `Retain` is a seatbelt. Switch to `Delete` only where data is provably disposable (dev), or use `archiveOnDelete` for a middle ground.
4. Diagnose `Pending`/`Failed`/`Lost`/`Terminating` via `oc describe` events **before** touching objects — the fix is usually upstream (provisioner, quota, pod, claim).

## Verification

```bash
# Cluster side — expect only Bound PVs
oc get pv
oc get pvc -A | grep -v Bound || echo "all claims bound"

# Server side — expect 54Gi freed
ssh core@192.168.29.10 'df -h /var/nfs/dynamic/ && ls /var/nfs/dynamic/'
```
