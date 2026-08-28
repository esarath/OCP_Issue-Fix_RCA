# Issue 15 — Redis (App + DB Tier) Deployment via OpenShift GitOps — LLD

| Field | Detail |
|---|---|
| **Date** | 2026-08-28 |
| **Type** | Planned Deployment (Low-Level Design — reviewed, not yet executed) |
| **Status** | LLD drafted, architecture-reviewed, and revised to v2. **Not yet implemented on the cluster** — no `redis-platform` namespace, Applications, or workloads exist yet. |
| **Scope** | Deploy a Redis cache tier (`redis-app`) + a persistent Redis datastore tier (`redis-db`) into a new `redis-platform` namespace on `lab.ocp.local`, fully managed via OpenShift GitOps (ArgoCD) |
| **Target Namespace** | `redis-platform` (new) |
| **Full LLD** | [Redis-OCP-GitOps-LLD.md](Redis-OCP-GitOps-LLD.md) |

---

## Summary

Low-level design for a GitOps-managed Redis deployment: a stateless-leaning cache tier (`redis-app`, Deployment, `emptyDir`, 2 replicas) and a durable datastore tier (`redis-db`, StatefulSet, AOF-persisted PVC), both reconciled by OpenShift GitOps under a shared `AppProject`. Went through two review passes before being marked ready to execute — see [Key Design Decisions](#key-design-decisions-v2-review) below for what changed and why.

## Cluster facts checked as part of this review

- Default StorageClass `nfs-storage` (community `nfs-subdir-external-provisioner:v4.0.2`) confirmed to support RWO — proven by existing bound PVCs (`prometheus-k8s-db-*`), not just theoretical.
- Cluster is on **4.20.35** (confirmed live — the LLD's original draft had a stale `4.19.43` header from before [issue 14](../14-419-to-420-upgrade-execution/)'s upgrade).
- `openshift-gitops-operator` is **not yet installed** on this cluster — Phase B of the LLD is a real prerequisite, not a formality.
- NFS export backing `nfs-storage` currently has **37GB free of 50GB** (unchanged from the 38GB free noted in [issue 05](../05-mtv-vm-migration-readiness/)) — comfortable headroom for the planned 10Gi `redis-db` PVC. Note the provisioner doesn't enforce per-PVC quotas (shared filesystem), so actual usage should still be monitored, not just the requested size.

## Key Design Decisions (v2 review)

The first draft had one architectural flaw and one internal contradiction; both are fixed in the LLD linked above.

| Issue found | Fix applied |
|---|---|
| Shared `redis-platform` namespace was tracked inside the `redis-app` Application's own Git path — deleting/repathing `redis-app-appl` would have cascade-deleted the namespace, taking `redis-db`'s StatefulSet and PVC down with it | Split into a dedicated `redis-platform-appl` Application (sync-wave 0) that solely owns the namespace + governance objects; neither tier's Application may track a `Namespace` manifest |
| Section 6 selected "Bitnami Helm chart" as the deployment mechanism, but the actual manifests were hand-written raw Kustomize YAML — the document contradicted itself | Resolved in favor of raw Kustomize manifests (what was actually written); doc text and repo layout now agree |
| No liveness/readiness probes defined, despite the validation checklist requiring them | Added exec-based `redis-cli ... --no-auth-warning ping` probes to both tiers |
| No `PodDisruptionBudget` on either tier, despite the 2-worker HA limitation being called out explicitly | Added `PodDisruptionBudget` (`minAvailable: 1`) to both tiers |
| AOF enabled via an unverified raw `--appendonly yes` CLI arg | Switched to Bitnami-documented `REDIS_AOF_ENABLED=yes` + `REDIS_EXTRA_FLAGS: "--appendfsync everysec"` — also ties the fsync policy to the NFS latency risk below |
| NFS-backed persistence risk (fsync/file-locking under AOF) not documented | Documented explicitly as an accepted, mitigated risk (`appendfsync everysec`, not `always`) |
| Bitnami image registry reachability assumed, not verified | Added a pre-check step (test-pull `docker.io/bitnami/redis:7.2`) — Broadcom's 2025 changes to Bitnami's free-tier image distribution make this worth confirming before build, not after |
| `storageClassName` left implicit on the PVC | Pinned explicitly to `nfs-storage` |

## Related

- [Issue 14](../14-419-to-420-upgrade-execution/) — cluster upgraded to 4.20.35, the version this LLD is designed against
- [Issue 05](../05-mtv-vm-migration-readiness/) — original finding on `nfs-storage`'s limited underlying capacity (38GB free at the time); re-checked here as still comfortable (37GB free) for this workload
