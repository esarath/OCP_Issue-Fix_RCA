# Issue 15 — Redis (App + DB Tier) Deployment via OpenShift GitOps — LLD

| Field | Detail |
|---|---|
| **Date** | 2026-08-28 |
| **Type** | Planned Deployment (Low-Level Design — reviewed, in manual hands-on execution) |
| **Status** | LLD at v4. **Execution in progress, run manually by the owner** (not automated by this repo's tooling) — Phase C (namespace + governance) complete and `Synced`/`Healthy`; Phase D onward not yet started. |
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

## v3 update — the Step 4 pre-check caught a real failure

Running Step 4 manually on the live cluster confirmed the predicted risk: `docker.io/bitnami/redis:7.2` fails with `manifest unknown`. Bitnami's free-tier `bitnami/redis` repo now publishes **only rolling `sha256-*` digest tags** — the fixed version tag never existed to pull. Repinned to `docker.io/bitnamilegacy/redis:7.2.5-debian-12-r6` (the frozen legacy archive, last updated 2025-07-18) and verified it live: pod ran to completion, printed `Redis server v=7.2.5`. This is now the image reference used throughout the LLD's Phase F manifests — see the v3 revision-history entry and the new "Image source" row in Section 6 of the linked LLD.

## v4 update — two real failures hit executing Phase C (Steps 8–9), both fixed

Running Steps 8–9 by hand surfaced two issues the review passes couldn't have caught without actually syncing against a live ArgoCD instance:

1. **Placeholder repo URL applied literally.** `<org>/gitops-repo.git` from the LLD's example YAML was applied as-is, leaving `redis-platform-appl` stuck `SYNC STATUS: Unknown` with `ComparisonError: repository not found`. Fixed by creating a real repo, [`esarath/redis-gitops`](https://github.com/esarath/redis-gitops), pushing the `apps/`/`clusters/` structure to it, and patching the AppProject's `sourceRepos` and the Application's `source.repoURL` to point at it.
2. **`ResourceQuota`/`LimitRange` sync forbidden.** Once the repo pointed correctly, sync still failed: `resourcequotas is forbidden` / `limitranges is forbidden`. Root cause: OpenShift GitOps' auto-granted namespace role for the `argocd-application-controller` service account explicitly restricts those two kinds to `get/list/watch`, even though it grants near-admin (`*`) on everything else in a GitOps-managed namespace — a deliberate platform guardrail (a GitOps app can't grant itself its own quota), not a bug. Fixed by moving both manifests out of the ArgoCD-tracked `apps/redis-platform/base/` into `apps/redis-platform/manual/` (not referenced by any `kustomization.yaml`) and applying them out-of-band via `oc apply` — the same pattern already used for Secrets in Phase D. `redis-platform-appl` is now `Synced`/`Healthy`.

Both fixes are reflected in the v4 LLD (new Step 9a, updated Section 5/6/7/10) and in `redis-gitops` itself (commits `b238ea6` and `8dadf5e`).

(A third issue hit along the way — the ArgoCD web UI being unreachable from a separate Windows machine on the LAN — turned out to be that machine's DNS configuration, not a defect in this deployment or repo, so it's not tracked here.)

## Related

- [Issue 14](../14-419-to-420-upgrade-execution/) — cluster upgraded to 4.20.35, the version this LLD is designed against
- [Issue 05](../05-mtv-vm-migration-readiness/) — original finding on `nfs-storage`'s limited underlying capacity (38GB free at the time); re-checked here as still comfortable (37GB free) for this workload
- [esarath/redis-gitops](https://github.com/esarath/redis-gitops) — the ArgoCD source repo this LLD actually syncs against
