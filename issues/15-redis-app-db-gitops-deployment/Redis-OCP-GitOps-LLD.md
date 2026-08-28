# Low-Level Design (LLD) Document
## Redis (App + DB Tier) Deployment on OpenShift via GitOps (ArgoCD)

| Field | Value |
|---|---|
| Document Type | Low-Level Design (LLD) |
| Target Platform | Red Hat OpenShift Container Platform (OCP) |
| Cluster Version | 4.20.35 (compatible 4.19.x – 4.20.x) |
| Cluster Topology | 3 Master + 2 Worker (on-prem, bare-metal) |
| Deployment Method | OpenShift GitOps (ArgoCD) — Application-of-Apps pattern, raw Kustomize manifests |
| Scope | Redis App-tier cache + Redis DB-tier persistent instance |
| Owner | Platform/DevOps Engineering |
| Revision | v4 |

**Revision History**

| Version | Date | Change |
|---|---|---|
| v1 | 2026-08-27 | Initial draft |
| v2 | 2026-08-28 | Architecture review: split namespace/governance objects into a dedicated `redis-platform-appl` Application to remove a cross-tier delete blast radius; resolved a Helm-vs-raw-manifest contradiction in favor of raw Kustomize manifests; added liveness/readiness probes and PodDisruptionBudgets; switched AOF enablement to Bitnami-documented env vars; pinned `storageClassName`; documented NFS persistence risk and Bitnami registry reachability risk; corrected stale cluster-version header |
| v3 | 2026-08-28 | Step 4's pre-check caught the predicted Bitnami registry risk for real: `docker.io/bitnami/redis:7.2` no longer resolves — Bitnami's free-tier repo now only publishes rolling `sha256-*` digest tags, no fixed version tags. Repinned the image to `docker.io/bitnamilegacy/redis:7.2.5-debian-12-r6` (verified pulling and running on this cluster) across Step 4 and both Phase F manifests |
| v4 | 2026-08-28 | Two real failures hit executing Steps 8–9 (Phase C) on the live cluster, both fixed: (1) the doc's `<org>/gitops-repo.git` placeholder was applied literally, leaving `redis-platform-appl` stuck `Unknown`/`ComparisonError: repository not found` — a real repo (`esarath/redis-gitops`) was created and both `sourceRepos`/`repoURL` fixed; (2) `ResourceQuota`/`LimitRange` sync failed with `... is forbidden` — OpenShift GitOps' auto-granted namespace role deliberately excludes `create` on those two kinds even though it grants near-admin on everything else. Moved both out of the ArgoCD-tracked `base/` into a `manual/` folder, applied out-of-band (new Step 9a) |

---

## 1. Purpose & Scope

This LLD defines the exact technical design and execution sequence to deploy **Redis** on an existing OCP 4.19.x/4.20.x cluster into a **new dedicated namespace**, with lifecycle management fully delegated to **OpenShift GitOps (ArgoCD)**. Two logical Redis workloads are covered:

- **redis-app** — stateless-leaning, low-latency cache tier (2-replica, no strict durability requirement)
- **redis-db** — persistent, durable Redis instance backed by PVC (AOF persistence enabled), used as a lightweight datastore

Both share a single namespace but are deployed as **three** separate ArgoCD `Application` objects under a shared `AppProject`, sourced from a Git repository, and reconciled automatically:

1. `redis-platform-appl` — owns the shared namespace and its governance objects (sync-wave 0)
2. `redis-app-appl` — owns the cache tier (sync-wave 1)
3. `redis-db-appl` — owns the DB tier (sync-wave 1)

Splitting the namespace into its own Application is a deliberate design choice, not an implementation detail — see Section 5.

---

## 2. Assumptions & Constraints

| # | Item | Detail |
|---|---|---|
| 1 | Cluster access | `cluster-admin` or namespace-admin + OperatorHub install rights via `oc` CLI |
| 2 | Node capacity | 2 workers only → HA (Sentinel/replica) is best-effort, not full anti-affinity-safe; documented limitation, mitigated with `PodDisruptionBudget`s (Section 6) |
| 3 | Storage | Default `StorageClass` (`nfs-storage`, community `nfs-subdir-external-provisioner`) supports RWO — confirmed live on this cluster. **NFS-backed persistence carries a known fsync/file-locking risk** for AOF-heavy workloads; mitigated via `appendfsync everysec` (never `always`) — see Section 10 |
| 4 | Git repo | Accessible Git remote (GitHub/GitLab) reachable from the ArgoCD instance |
| 5 | Registry | Public registry access (`docker.io`, `quay.io`) confirmed live on this cluster. **Confirmed impact of Bitnami's 2025 catalog changes:** `docker.io/bitnami/redis:7.2` fails with `manifest unknown` — the free-tier `bitnami/redis` repo now publishes only rolling `sha256-*` digest tags, no fixed version tags. Using `docker.io/bitnamilegacy/redis:7.2.5-debian-12-r6` instead (verified pull + run, Step 4) — a frozen archive (last updated 2025-07-18, no further security patches), acceptable for this lab/POC scope but not a long-term production choice |
| 6 | Secrets | No plaintext secrets committed to Git — created out-of-band via `oc create secret` (decision finalized, Section 6) |
| 7 | Networking | Default OVN-Kubernetes CNI; NetworkPolicy support available |

---

## 3. Target Architecture

```
                         ┌────────────────────────────────────────────────────┐
                         │                openshift-gitops (ns)                 │
                         │  ArgoCD Instance (Operator-managed)                  │
                         │  ┌─────────────┐   ┌──────────────────────────────┐│
                         │  │ AppProject:  │   │ Applications (sync-wave):    ││
                         │  │ redis-project│──▶│ 0: redis-platform-appl       ││
                         │  │ (scoped)     │   │    (namespace + governance)  ││
                         │  │              │   │ 1: redis-app-appl            ││
                         │  │              │   │ 1: redis-db-appl             ││
                         │  └─────────────┘   └──────────────────────────────┘│
                         └──────────────────────┬───────────────────────────────┘
                                                 │ sync (auto + self-heal + prune, per-Application)
                                                 ▼
                         ┌────────────────────────────────────────────────────┐
                         │   redis-platform (namespace — owned solely by       │
                         │   redis-platform-appl; never tracked by either tier)│
                         │                                                     │
                         │  ┌───────────────┐   ┌───────────────────┐        │
                         │  │ redis-app      │   │ redis-db           │        │
                         │  │ Deployment     │   │ StatefulSet         │        │
                         │  │ (2 replicas)   │   │ (1 primary +        │        │
                         │  │ emptyDir       │   │  optional 1 replica)│        │
                         │  │ PDB min=1      │   │ PVC (RWO, 10Gi)     │        │
                         │  │ Service:6379   │   │ PDB min=1           │        │
                         │  │                │   │ Service:6379        │        │
                         │  └───────────────┘   └───────────────────┘        │
                         │  Secret: redis-app-auth / redis-db-auth (out-of-band)│
                         │  ResourceQuota / LimitRange / default-deny NetworkPolicy│
                         │  (all owned by redis-platform-appl)                │
                         └────────────────────────────────────────────────────┘
                Worker-1 (2 vCPU/4Gi min)              Worker-2 (2 vCPU/4Gi min)
```

**Why the namespace is its own Application:** if the Namespace object were tracked inside `redis-app-appl` (as originally drafted), deleting or repathing that one Application would cascade-delete the shared namespace — taking `redis-db`'s StatefulSet and PVC down with it, even though `redis-db` is reconciled by a completely separate Application. Isolating the namespace and governance objects under `redis-platform-appl`, synced first via `argocd.argoproj.io/sync-wave: "0"`, removes that cross-tier blast radius entirely.

**Placement strategy** (2 workers only):
- `redis-app` pods: `podAntiAffinity` (preferred, not required) across the 2 workers, backed by a `PodDisruptionBudget` (`minAvailable: 1`)
- `redis-db` pod(s): rely on dynamic PVC binding (NFS is not node-local, so no topology pinning is needed); backed by its own `PodDisruptionBudget` (`minAvailable: 1`)

---

## 4. Component Inventory

| Component | Type | Namespace | Purpose |
|---|---|---|---|
| `openshift-gitops-operator` | Operator (OperatorHub) | `openshift-operators` | Installs ArgoCD control plane |
| `openshift-gitops` ArgoCD instance | Custom Resource | `openshift-gitops` | Default ArgoCD instance created by operator |
| `redis-project` | AppProject | `openshift-gitops` | Scopes source repo + destination namespace/kinds |
| `redis-platform-appl` | Application (sync-wave 0) | `openshift-gitops` | Owns the `redis-platform` namespace + governance objects (ResourceQuota, LimitRange, default-deny NetworkPolicy). **Never** owned by an app-tier Application. |
| `redis-app-appl` | Application (sync-wave 1) | `openshift-gitops` | Points to `apps/redis-app` Git path |
| `redis-db-appl` | Application (sync-wave 1) | `openshift-gitops` | Points to `apps/redis-db` Git path |
| `redis-platform` | Namespace/Project | cluster | Dedicated namespace for both Redis workloads; managed exclusively by `redis-platform-appl` |
| `redis-app` | Deployment + Service + PDB + Secret | `redis-platform` | Cache-tier Redis |
| `redis-db` | StatefulSet + Service + PDB + Secret + PVC | `redis-platform` | Persistent DB-tier Redis |

---

## 5. Namespace Design

**Name:** `redis-platform`

**Owned by:** `redis-platform-appl` only. Neither `redis-app-appl` nor `redis-db-appl` may include a `Namespace` manifest in its tracked path — this is the single most important invariant in this design (see Section 3 rationale). Enforce it in code review of any future manifest changes.

**Labels:**
```yaml
labels:
  argocd.argoproj.io/managed-by: openshift-gitops
  app.kubernetes.io/part-of: redis-platform
  environment: dev        # or staging/prod per overlay
```

**Governance objects**, split by how they're applied (see Step 9a for why):

*ArgoCD-managed* (tracked under `apps/redis-platform/base/`, sync-wave 0):
- `NetworkPolicy` — deny-all ingress by default, allow only from designated consumer namespaces (plus Prometheus scrape access if metrics are enabled later)

*Applied out-of-band* (tracked under `apps/redis-platform/manual/` for reference, but **not** referenced by any `kustomization.yaml` — ArgoCD never touches these):
- `ResourceQuota` — cap total CPU/memory/PVC count in namespace
- `LimitRange` — default request/limit per container

OpenShift GitOps' auto-granted namespace role for the `argocd-application-controller` service account explicitly restricts `resourcequotas`/`limitranges` to `get/list/watch` — no `create` — even though it grants near-admin (`*`) on almost everything else in a namespace carrying the `argocd.argoproj.io/managed-by: openshift-gitops` label. This is a deliberate platform guardrail (a GitOps app can't grant itself its own quota), confirmed live on this cluster: `resourcequotas is forbidden: User "system:serviceaccount:openshift-gitops:openshift-gitops-argocd-application-controller" cannot create resource "resourcequotas"...`. Don't work around it with extra RBAC — apply these two out-of-band instead, the same pattern already used for Secrets (Phase D).

---

## 6. Redis Deployment Design Decisions

| Decision Point | Options Evaluated | Selected | Rationale |
|---|---|---|---|
| Deployment mechanism | Raw manifests / Bitnami Helm chart / Redis Operator (community) | **Raw Kustomize manifests, `bitnami/redis` container image (not the Bitnami Helm chart)** | The chart's opinionated multi-object footprint (ConfigMap templating, primary/replica split, optional metrics sidecar) isn't needed at this scale; raw manifests give full control and are what's actually authored in Phase F — decided explicitly rather than left inconsistent with Section 7 |
| Image source | `docker.io/bitnami/redis:7.2` (rolling digest tags only, confirmed unreachable — Step 4) / `docker.io/bitnamilegacy/redis:<pinned tag>` / official `docker.io/redis:7.2` | **`docker.io/bitnamilegacy/redis:7.2.5-debian-12-r6`** (verified pull + run) | Smallest change from the reviewed design — keeps all Bitnami-specific conventions (env vars, `/bitnami/redis/data` path, non-root default) intact. Trade-off: frozen archive, no future security patches — acceptable for this lab/POC; revisit before any production use |
| Namespace/governance ownership | Bundled into `redis-app`'s tree / dedicated Application | **Dedicated `redis-platform-appl` Application, sync-wave 0** | Prevents an app-tier Application delete/repath from cascade-deleting the shared namespace and the other tier's data (Section 3) |
| redis-app topology | Single pod / Deployment (2 replicas, no persistence) | **Deployment, 2 replicas, `emptyDir`** | Cache doesn't need durability; 2 replicas spread across 2 workers for basic resilience |
| redis-db topology | Single instance / Sentinel (3 nodes) / Replica set | **StatefulSet, 1 primary + optional 1 replica, RWO PVC** | Only 2 workers available — full 3-node Sentinel quorum not feasible without over-subscribing nodes; documented as a scaling gap |
| Availability under node loss | No PDB / `PodDisruptionBudget` | **`PodDisruptionBudget` (`minAvailable: 1`) on both tiers** | 2-worker cluster means a single node drain can otherwise evict all replicas of a tier at once, silently, with no ArgoCD-visible signal |
| SCC | `anyuid` / `restricted-v2` (default) | **`restricted-v2`** (Bitnami images run as non-root by default ≥ chart v18) | Avoids granting `anyuid`, keeps PSA `restricted` compliance |
| Secrets | Plaintext Secret in Git / Sealed Secrets / External Secrets Operator | **Manual `oc create secret`, out-of-band** | Simplest GitOps-safe option at this scale; no sealed-secrets controller bootstrap dependency to manage |
| Governance objects (ResourceQuota, LimitRange) | Track in `apps/redis-platform/base/` like NetworkPolicy / grant the controller extra RBAC / apply out-of-band | **Apply out-of-band (Step 9a), same pattern as Secrets** | OpenShift GitOps' auto-granted namespace role deliberately excludes `create` on these two kinds (confirmed live: `resourcequotas is forbidden`/`limitranges is forbidden`) — granting extra RBAC would punch a hole in a guardrail the platform put there on purpose |
| Persistence | `emptyDir` / PVC / hostPath | **PVC, dynamic provisioning, `storageClassName: nfs-storage` (pinned explicitly), RWO, 10Gi (db) / none (app)** | Matches durability requirement for DB tier only; pinning the SC name avoids silently following a future change to the cluster default |
| AOF enablement | Raw `--appendonly yes` CLI arg / `REDIS_AOF_ENABLED` env var | **`REDIS_AOF_ENABLED: "yes"` + `REDIS_EXTRA_FLAGS: "--appendfsync everysec"`** | Both are documented Bitnami image env vars; avoids depending on untested entrypoint arg-passthrough behavior, and explicitly sets the fsync policy to mitigate the NFS latency risk in Section 2 |
| Health checks | None / exec-based probes | **Exec `redis-cli ... --no-auth-warning ping` liveness + readiness probes** | Required by the Section 9 validation checklist; `--no-auth-warning` keeps the password warning out of probe logs |
| Sync policy | Manual / Automated | **Automated with `selfHeal: true`, `prune: true`, per-Application** | True GitOps drift-correction behavior; safe now that each Application owns only its own tier's objects (no shared Namespace to prune) |

---

## 7. GitOps Repository Structure

```
gitops-repo/
├── clusters/
│   └── ocp-onprem/
│       └── redis-project.yaml          # AppProject
├── apps/
│   ├── redis-platform/                 # namespace + governance (sync-wave 0)
│   │   ├── application.yaml
│   │   ├── base/                       # ArgoCD-managed
│   │   │   ├── kustomization.yaml
│   │   │   ├── namespace.yaml
│   │   │   └── networkpolicy.yaml
│   │   └── manual/                     # NOT ArgoCD-managed — apply via `oc apply` (Step 9a)
│   │       ├── README.md
│   │       ├── resourcequota.yaml
│   │       └── limitrange.yaml
│   ├── redis-app/                      # cache tier (sync-wave 1)
│   │   ├── application.yaml
│   │   ├── base/
│   │   │   ├── kustomization.yaml
│   │   │   ├── deployment.yaml
│   │   │   ├── service.yaml
│   │   │   └── pdb.yaml
│   │   └── overlays/
│   │       └── dev/
│   │           └── kustomization.yaml
│   └── redis-db/                       # db tier (sync-wave 1)
│       ├── application.yaml
│       ├── base/
│       │   ├── kustomization.yaml
│       │   ├── statefulset.yaml
│       │   ├── service.yaml
│       │   └── pdb.yaml
│       └── overlays/
│           └── dev/
│               └── kustomization.yaml
```

---

## 8. Step-by-Step Execution Guide

> Convention: every step lists **WHERE TO EXECUTE**, the exact command/manifest, and **expected output / verification**.

### Phase A — Pre-Checks

**Step 1 — Verify cluster version and node topology**
**WHERE TO EXECUTE:** Bastion host / `oc` CLI (logged in as cluster-admin)
```bash
oc get clusterversion
oc get nodes -o wide
```
**Expected output:** `clusterversion` shows `4.19.x` or `4.20.x` (currently `4.20.35`); `get nodes` lists 3 `master`/`control-plane` roles + 2 `worker` roles, all `Ready`.

---

**Step 2 — Verify default StorageClass supports RWO**
**WHERE TO EXECUTE:** `oc` CLI
```bash
oc get storageclass
oc get storageclass -o jsonpath='{.items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")].metadata.name}'
```
**Expected output:** One StorageClass marked `(default)` — on this cluster, `nfs-storage` (provisioner `nfs-subdir-external-provisioner`), confirmed to support RWO via existing bound PVCs (e.g. `prometheus-k8s-db-*`). Note this is NFS-backed — see Section 2, Item 3 for the persistence-risk mitigation.

---

**Step 3 — Check available CPU/memory headroom on workers**
**WHERE TO EXECUTE:** `oc` CLI
```bash
oc adm top nodes
oc describe node <worker-node-1> | grep -A5 "Allocated resources"
```
**Expected output:** Sufficient allocatable CPU/mem for ~2×(0.5 CPU/512Mi) app pods + 1×(1 CPU/1Gi) db pod across the 2 workers, on top of existing cluster workloads (monitoring, registry, etc. already resident there).

---

**Step 4 — Verify the Redis image actually pulls from this cluster**
**WHERE TO EXECUTE:** `oc` CLI
```bash
oc run bitnami-pull-test --rm -i --restart=Never \
  --image=docker.io/bitnamilegacy/redis:7.2.5-debian-12-r6 -- redis-server --version
```
**Expected output:** Pod runs to completion and prints the Redis version banner (`Redis server v=7.2.5 ...`).

**Already run on this cluster:** the original `docker.io/bitnami/redis:7.2` failed with `manifest unknown` — Bitnami's free-tier `bitnami/redis` repo now publishes only rolling `sha256-*` digest tags (Broadcom's 2025 catalog change), no fixed version tags at all. `docker.io/bitnamilegacy/redis:7.2.5-debian-12-r6` was confirmed working instead (pod `Succeeded`, printed `Redis server v=7.2.5`) and is the tag used throughout Phase F below. If this tag itself ever stops resolving, check current tags at `hub.docker.com/r/bitnamilegacy/redis/tags` before falling back to mirroring or switching to the official `docker.io/redis` image (which uses different env vars/paths — see Section 6, "Image source" row).

---

### Phase B — Install OpenShift GitOps Operator

**Step 5 — Install the OpenShift GitOps Operator subscription**
**WHERE TO EXECUTE:** `oc` CLI (apply manifest) or OperatorHub UI
```yaml
# openshift-gitops-subscription.yaml
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: openshift-gitops-operator
  namespace: openshift-operators
spec:
  channel: latest
  name: openshift-gitops-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
  installPlanApproval: Automatic
```
```bash
oc apply -f openshift-gitops-subscription.yaml
```
**Expected output:** `subscription.operators.coreos.com/openshift-gitops-operator created`

---

**Step 6 — Verify operator install and default ArgoCD instance**
**WHERE TO EXECUTE:** `oc` CLI
```bash
oc get csv -n openshift-operators | grep gitops
oc get pods -n openshift-gitops
oc get argocd -n openshift-gitops
```
**Expected output:** CSV `Succeeded`; pods (`openshift-gitops-server`, `openshift-gitops-repo-server`, `openshift-gitops-application-controller`, `openshift-gitops-redis`, etc.) all `Running`; one `argocd` CR named `openshift-gitops`.

---

**Step 7 — Retrieve ArgoCD admin credentials & route**
**WHERE TO EXECUTE:** `oc` CLI
```bash
oc get route openshift-gitops-server -n openshift-gitops -o jsonpath='{.spec.host}'
ARGOCD_PWD=$(oc extract secret/openshift-gitops-cluster -n openshift-gitops --to=- --keys=admin.password)
```
**Expected output:** Route hostname printed; admin password captured to a local shell variable (avoid printing credentials directly into shared runbook/CI logs). Login test via browser or `argocd login <route> --username admin --password "$ARGOCD_PWD" --insecure`.

---

### Phase C — Namespace & Governance (sync-wave 0)

**Step 8 — Define the AppProject scoping repo + destination**
**WHERE TO EXECUTE:** `oc` CLI or Git repo (`clusters/ocp-onprem/redis-project.yaml`)
```yaml
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: redis-project
  namespace: openshift-gitops
spec:
  description: Redis platform + app + db GitOps project
  sourceRepos:
    - 'https://github.com/<org>/gitops-repo.git'
  destinations:
    - namespace: redis-platform
      server: https://kubernetes.default.svc
  clusterResourceWhitelist:
    - group: ''
      kind: Namespace
  namespaceResourceWhitelist:
    - group: '*'
      kind: '*'
```
```bash
oc apply -f clusters/ocp-onprem/redis-project.yaml
```
**Expected output:** `appproject.argoproj.io/redis-project created`; `oc get appproject -n openshift-gitops` lists it.

**Don't leave `<org>/gitops-repo.git` as literal text.** Replace it with your actual repository URL before applying — this bit us on this cluster: `redis-platform-appl` (Step 9) got stuck `SYNC STATUS: Unknown` with `ComparisonError: failed to list refs: repository not found: Repository not found.` because the placeholder was applied verbatim. The URL used for this actual deployment is `https://github.com/esarath/redis-gitops.git` — substitute your own equivalent everywhere `<org>/gitops-repo.git` appears (this file, both `sourceRepos` and every Application's `source.repoURL`).

---

**Step 9 — Create the `redis-platform` Application (namespace + governance objects)**
**WHERE TO EXECUTE:** Git repo (`apps/redis-platform/application.yaml`), then applied via `oc`

This Application is the **sole owner** of the `redis-platform` Namespace. `redis-app-appl` and `redis-db-appl` (Phase E) must never track a `Namespace` manifest.

```yaml
# apps/redis-platform/base/namespace.yaml
apiVersion: v1
kind: Namespace
metadata:
  name: redis-platform
  labels:
    argocd.argoproj.io/managed-by: openshift-gitops
    app.kubernetes.io/part-of: redis-platform
```

```yaml
# apps/redis-platform/application.yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: redis-platform-appl
  namespace: openshift-gitops
  annotations:
    argocd.argoproj.io/sync-wave: "0"
spec:
  project: redis-project
  source:
    repoURL: 'https://github.com/<org>/gitops-repo.git'
    targetRevision: main
    path: apps/redis-platform/base
  destination:
    server: https://kubernetes.default.svc
    namespace: redis-platform
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```
```bash
oc apply -f apps/redis-platform/application.yaml
```
**Expected output:** `application.argoproj.io/redis-platform-appl created`; after sync, `oc get ns redis-platform` shows `Active`. At this point `oc get networkpolicy -n redis-platform` will show the two NetworkPolicy objects, but `oc get resourcequota,limitrange -n redis-platform` will show **nothing yet** — that's expected, see Step 9a.

---

**Step 9a — Apply `ResourceQuota` and `LimitRange` out-of-band**
**WHERE TO EXECUTE:** `oc` CLI (bastion) — NOT tracked by ArgoCD

If you skip this step, `redis-platform-appl`'s sync will show `OutOfSync` indefinitely with an operation error containing `resourcequotas is forbidden` / `limitranges is forbidden` — confirmed live on this cluster. This is OpenShift GitOps' auto-granted namespace role deliberately withholding `create` on these two kinds; it is not a misconfiguration to fix with extra RBAC (see Section 5).

```bash
oc apply -f apps/redis-platform/manual/resourcequota.yaml
oc apply -f apps/redis-platform/manual/limitrange.yaml

# force ArgoCD to re-compare immediately rather than waiting for its ~3min poll
oc annotate application redis-platform-appl -n openshift-gitops argocd.argoproj.io/refresh=hard --overwrite
```
**Expected output:** `resourcequota/redis-platform-quota created`, `limitrange/redis-platform-limits created`; within a few seconds, `oc get application redis-platform-appl -n openshift-gitops` shows `SYNC STATUS: Synced`, `HEALTH STATUS: Healthy`.

---

### Phase D — Secrets (Out-of-Band, Pre-Sync)

**Step 10 — Create Redis auth secrets manually**
**WHERE TO EXECUTE:** `oc` CLI (bastion) — NOT committed to Git in plaintext
**Pre-requisite:** `redis-platform` namespace exists (confirmed at end of Step 9)
```bash
oc create secret generic redis-app-auth \
  --from-literal=redis-password='<STRONG_PASSWORD_1>' \
  -n redis-platform
oc create secret generic redis-db-auth \
  --from-literal=redis-password='<STRONG_PASSWORD_2>' \
  -n redis-platform
```
**Expected output:** `secret/redis-app-auth created`, `secret/redis-db-auth created`.

---

### Phase E — Define ArgoCD Applications (sync-wave 1)

**Step 11 — Create the `redis-app` Application manifest**
**WHERE TO EXECUTE:** Git repo (`apps/redis-app/application.yaml`), then applied via `oc`
```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: redis-app-appl
  namespace: openshift-gitops
  annotations:
    argocd.argoproj.io/sync-wave: "1"
spec:
  project: redis-project
  source:
    repoURL: 'https://github.com/<org>/gitops-repo.git'
    targetRevision: main
    path: apps/redis-app/overlays/dev
  destination:
    server: https://kubernetes.default.svc
    namespace: redis-platform
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=false
```
```bash
oc apply -f apps/redis-app/application.yaml
```
**Expected output:** `application.argoproj.io/redis-app-appl created`

---

**Step 12 — Create the `redis-db` Application manifest**
**WHERE TO EXECUTE:** Git repo (`apps/redis-db/application.yaml`), then applied via `oc`
```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: redis-db-appl
  namespace: openshift-gitops
  annotations:
    argocd.argoproj.io/sync-wave: "1"
spec:
  project: redis-project
  source:
    repoURL: 'https://github.com/<org>/gitops-repo.git'
    targetRevision: main
    path: apps/redis-db/overlays/dev
  destination:
    server: https://kubernetes.default.svc
    namespace: redis-platform
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=false
```
```bash
oc apply -f apps/redis-db/application.yaml
```
**Expected output:** `application.argoproj.io/redis-db-appl created`

---

### Phase F — Redis Manifests (raw Kustomize content in Git)

**Step 13 — Define `redis-app` Deployment + Service + PodDisruptionBudget (base)**
**WHERE TO EXECUTE:** Git repo (`apps/redis-app/base/deployment.yaml`, `service.yaml`, `pdb.yaml`)
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: redis-app
  namespace: redis-platform
spec:
  replicas: 2
  selector:
    matchLabels: { app: redis-app }
  template:
    metadata:
      labels: { app: redis-app }
    spec:
      affinity:
        podAntiAffinity:
          preferredDuringSchedulingIgnoredDuringExecution:
            - weight: 100
              podAffinityTerm:
                labelSelector:
                  matchLabels: { app: redis-app }
                topologyKey: kubernetes.io/hostname
      containers:
        - name: redis
          image: docker.io/bitnamilegacy/redis:7.2.5-debian-12-r6
          env:
            - name: REDIS_PASSWORD
              valueFrom:
                secretKeyRef: { name: redis-app-auth, key: redis-password }
          ports: [{ containerPort: 6379 }]
          resources:
            requests: { cpu: 250m, memory: 256Mi }
            limits: { cpu: 500m, memory: 512Mi }
          volumeMounts:
            - name: data
              mountPath: /bitnami/redis/data
          livenessProbe:
            exec:
              command: ["redis-cli", "-a", "$(REDIS_PASSWORD)", "--no-auth-warning", "ping"]
            initialDelaySeconds: 15
            periodSeconds: 10
          readinessProbe:
            exec:
              command: ["redis-cli", "-a", "$(REDIS_PASSWORD)", "--no-auth-warning", "ping"]
            initialDelaySeconds: 5
            periodSeconds: 5
      volumes:
        - name: data
          emptyDir: {}
---
apiVersion: v1
kind: Service
metadata:
  name: redis-app
  namespace: redis-platform
spec:
  selector: { app: redis-app }
  ports: [{ port: 6379, targetPort: 6379 }]
---
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: redis-app
  namespace: redis-platform
spec:
  minAvailable: 1
  selector:
    matchLabels: { app: redis-app }
```
**Expected output (post-sync):** `oc get deploy redis-app -n redis-platform` shows `2/2` ready; `oc get pdb redis-app -n redis-platform` shows `ALLOWED DISRUPTIONS: 1`.

---

**Step 14 — Define `redis-db` StatefulSet + Service + PVC template + PodDisruptionBudget (base)**
**WHERE TO EXECUTE:** Git repo (`apps/redis-db/base/statefulset.yaml`, `service.yaml`, `pdb.yaml`)
```yaml
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: redis-db
  namespace: redis-platform
spec:
  serviceName: redis-db
  replicas: 1
  selector:
    matchLabels: { app: redis-db }
  template:
    metadata:
      labels: { app: redis-db }
    spec:
      containers:
        - name: redis
          image: docker.io/bitnamilegacy/redis:7.2.5-debian-12-r6
          env:
            - name: REDIS_PASSWORD
              valueFrom:
                secretKeyRef: { name: redis-db-auth, key: redis-password }
            - name: REDIS_AOF_ENABLED
              value: "yes"
            - name: REDIS_EXTRA_FLAGS
              value: "--appendfsync everysec"
          ports: [{ containerPort: 6379 }]
          resources:
            requests: { cpu: 500m, memory: 512Mi }
            limits: { cpu: 1, memory: 1Gi }
          volumeMounts:
            - name: data
              mountPath: /bitnami/redis/data
          livenessProbe:
            exec:
              command: ["redis-cli", "-a", "$(REDIS_PASSWORD)", "--no-auth-warning", "ping"]
            initialDelaySeconds: 15
            periodSeconds: 10
          readinessProbe:
            exec:
              command: ["redis-cli", "-a", "$(REDIS_PASSWORD)", "--no-auth-warning", "ping"]
            initialDelaySeconds: 5
            periodSeconds: 5
  volumeClaimTemplates:
    - metadata: { name: data }
      spec:
        accessModes: ["ReadWriteOnce"]
        storageClassName: nfs-storage
        resources: { requests: { storage: 10Gi } }
---
apiVersion: v1
kind: Service
metadata:
  name: redis-db
  namespace: redis-platform
spec:
  clusterIP: None
  selector: { app: redis-db }
  ports: [{ port: 6379, targetPort: 6379 }]
---
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: redis-db
  namespace: redis-platform
spec:
  minAvailable: 1
  selector:
    matchLabels: { app: redis-db }
```
**Expected output (post-sync):** `oc get statefulset redis-db -n redis-platform` shows `1/1`; `oc get pvc -n redis-platform` shows `data-redis-db-0` `Bound` with `STORAGECLASS: nfs-storage`.

**Note on `appendfsync everysec`:** this trades a small durability window (≤1s of writes on a hard crash) for materially better write latency and lower fsync pressure on the NFS-backed volume — appropriate given Section 2's documented NFS risk. Do not use `always` on this storage backend.

---

**Step 15 — Commit and push all manifests**
**WHERE TO EXECUTE:** Local Git client / laptop
```bash
git add apps/ clusters/
git commit -m "Add Redis platform+app+db GitOps manifests"
git push origin main
```
**Expected output:** Push succeeds; commit visible in remote repo history.

---

### Phase G — Sync & Verify

**Step 16 — Confirm ArgoCD Applications reach Synced/Healthy**
**WHERE TO EXECUTE:** `oc` CLI or ArgoCD UI/CLI
```bash
oc get application -n openshift-gitops
argocd app get redis-platform-appl
argocd app get redis-app-appl
argocd app get redis-db-appl
```
**Expected output:** `SYNC STATUS: Synced`, `HEALTH STATUS: Healthy` for all three applications, with `redis-platform-appl` synced first (sync-wave 0).

---

**Step 17 — Force sync if not auto-synced yet**
**WHERE TO EXECUTE:** `oc` CLI (via `argocd` CLI) or ArgoCD UI
```bash
argocd app sync redis-platform-appl
argocd app sync redis-app-appl
argocd app sync redis-db-appl
```
**Expected output:** Sync operation completes with `Succeeded` phase, in that order.

---

**Step 18 — Validate Redis connectivity (App tier)**
**WHERE TO EXECUTE:** `oc` CLI (exec into pod)
```bash
oc exec -n redis-platform deploy/redis-app -- redis-cli -a <REDIS_APP_PASSWORD> --no-auth-warning PING
```
**Expected output:** `PONG`

---

**Step 19 — Validate Redis connectivity + persistence (DB tier)**
**WHERE TO EXECUTE:** `oc` CLI (exec into pod)
```bash
oc exec -n redis-platform redis-db-0 -- redis-cli -a <REDIS_DB_PASSWORD> --no-auth-warning PING
oc exec -n redis-platform redis-db-0 -- redis-cli -a <REDIS_DB_PASSWORD> --no-auth-warning SET testkey "hello"
oc exec -n redis-platform redis-db-0 -- redis-cli -a <REDIS_DB_PASSWORD> --no-auth-warning GET testkey
```
**Expected output:** `PONG`, `OK`, `"hello"` respectively. Optionally delete the pod and confirm `GET testkey` still returns `"hello"` after the StatefulSet recreates it (validates PVC persistence).

---

## 9. Post-Deployment Validation Checklist

| Check | Command | Pass Criteria |
|---|---|---|
| ArgoCD sync/health (all 3 Applications) | `oc get application -n openshift-gitops` | `Synced` / `Healthy`; `redis-platform-appl` present and not owned by an app-tier path |
| Governance objects present (namespace-wide) | `oc get resourcequota,limitrange,networkpolicy -n redis-platform` | All three present — `ResourceQuota`/`LimitRange` applied manually (Step 9a), `NetworkPolicy` ×2 via ArgoCD |
| Pod readiness | `oc get pods -n redis-platform` | All `Running`, `READY 1/1` |
| PVC bound | `oc get pvc -n redis-platform` | `Bound`, `STORAGECLASS: nfs-storage` |
| PodDisruptionBudgets present | `oc get pdb -n redis-platform` | `redis-app` and `redis-db` both present, `minAvailable: 1` |
| Probes configured | `oc describe pod <redis-pod> -n redis-platform` | liveness/readiness probes present and passing |
| Logs clean | `oc logs <redis-pod> -n redis-platform` | No auth errors, no crash loops |
| Metrics (if Prometheus present) | `oc get servicemonitor -n redis-platform` | ServiceMonitor scraping (optional, add Bitnami exporter sidecar) |
| Rollback path | `argocd app history redis-db-appl` | Prior revisions listed; `argocd app rollback redis-db-appl <ID>` works |

---

## 10. Known Pitfalls & Troubleshooting

| Symptom | Likely Cause | Resolution |
|---|---|---|
| Pod stuck `CreateContainerConfigError` | SCC denies non-root UID mismatch | Confirm image runs as non-root; avoid requesting `anyuid` SCC unless required |
| PVC stuck `Pending` | `storageClassName` mismatch, or StorageClass doesn't support RWO | `oc get storageclass`; confirm `storageClassName: nfs-storage` in `volumeClaimTemplates` matches the actual SC name |
| Redis write stalls / high latency under load (DB tier) | NFS fsync/file-locking overhead under `appendfsync always` or heavy write bursts | Confirm `appendfsync everysec` is set (not `always`); monitor AOF rewrite duration; this is an accepted trade-off of the NFS-backed default StorageClass |
`manifest unknown` pulling `bitnami/redis:<tag>` | Confirmed on this cluster (2026-08-28): Bitnami's free-tier repo now serves only rolling `sha256-*` digest tags, no fixed version tags | Use `docker.io/bitnamilegacy/redis:7.2.5-debian-12-r6` (already the pinned tag in this doc/Phase F) — frozen archive, no future patches, acceptable for lab/POC scope |
| `ImagePullBackOff`/`ErrImagePull` on `bitnamilegacy/redis` | Tag removed from the legacy archive, or air-gapped cluster with no route to `docker.io` | Re-run Step 4's pull test; check current tags at `hub.docker.com/r/bitnamilegacy/redis/tags`; mirror the image internally or pin a different tag; update `image:` field in overlay |
| Deleting/repathing `redis-app-appl` also removes `redis-db`'s namespace | A `Namespace` manifest was added to an app-tier Application's tracked path, violating the Section 5 invariant | Keep `Namespace` and governance objects solely under `apps/redis-platform/base/`, owned only by `redis-platform-appl` — never add a `Namespace` manifest to `redis-app` or `redis-db` |
| `redis-platform-appl` stuck `SYNC STATUS: Unknown`, `ComparisonError: ... repository not found` | The `<org>/gitops-repo.git` placeholder in `sourceRepos`/`repoURL` was applied literally instead of being replaced with a real repo URL — confirmed on this cluster | Create a real Git repo, push the `apps/`/`clusters/` structure to it, and `oc patch`/`oc apply` the AppProject and every Application's `repoURL` to point at it (Step 8/9) |
| `redis-platform-appl` `OutOfSync` forever, operation error contains `resourcequotas is forbidden` / `limitranges is forbidden` | OpenShift GitOps' auto-granted namespace role withholds `create` on these two kinds specifically, even with near-admin on everything else — confirmed on this cluster | Apply `ResourceQuota`/`LimitRange` out-of-band (Step 9a); don't grant the controller SA extra RBAC to work around it |
| ArgoCD `OutOfSync` in a loop | Immutable field changed (e.g., `serviceName`, PVC size shrink) | Delete and recreate the resource via a Git-tracked change, not manual `oc edit` |
| ArgoCD can't reach Git repo | Firewall/proxy blocking outbound HTTPS from `openshift-gitops-repo-server` | Configure repo-server proxy env vars or use internal Git mirror |
| Redis `NOAUTH` errors in app logs | Secret not mounted or wrong key name | Verify `secretKeyRef.key` matches secret data key exactly |
| Sentinel/HA not achievable | Only 2 workers available | Documented limitation — use 1 primary + 1 replica async, not full 3-node quorum; `PodDisruptionBudget` limits (not eliminates) simultaneous-eviction risk |

---

## 11. Rollback Strategy

1. **Git-level rollback:** `git revert <bad-commit>` → push → ArgoCD auto-syncs to previous state (self-heal). Applies independently per Application — a bad `redis-app` commit does not require touching `redis-db` or `redis-platform`.
2. **ArgoCD-level rollback:** `argocd app rollback redis-db-appl <history-id>` for immediate rollback without a Git revert (use only for emergency, then reconcile Git afterward to avoid drift).
3. **Data rollback (DB tier only):** if Redis persistence (AOF) is enabled and the PVC survives, pod restarts do not lose data; for corruption, restore from PVC snapshot/backup if configured. The `redis-platform-appl`/namespace split means a `redis-db-appl` rollback or deletion cannot take the PVC's namespace down with it.

---

## 12. Interview / POC Summary (3 bullets)

- Designed and implemented a **GitOps-first Redis platform** on a resource-constrained on-prem OCP cluster (3 master/2 worker) using OpenShift GitOps (ArgoCD), separating namespace/governance, cache-tier (ephemeral), and DB-tier (PVC-backed, AOF-persisted) concerns into three independently reconciled, sync-wave-ordered ArgoCD Applications under a scoped AppProject — explicitly avoiding a cross-tier delete blast radius where one tier's Application could cascade-delete another tier's data.
- Enforced **GitOps-safe secrets handling** (no plaintext credentials in Git), SCC-compliant (`restricted-v2`) pod security, health-checked pods (exec-based liveness/readiness probes), `PodDisruptionBudget`-protected availability, and automated drift-correction (`selfHeal`+`prune`) — demonstrating production SRE discipline in a POC footprint.
- Explicitly documented and worked around infrastructure constraints rather than over-engineering around them: the **HA limitation of a 2-worker cluster** (no full 3-node Sentinel quorum) and the **NFS-backed storage's fsync trade-offs** (`appendfsync everysec`) are both accepted, mitigated, and written down — not silently assumed away.
