# Issue 33 — ResourceQuota Controls: Namespace Resource Governance & Quota Troubleshooting

| Field | Detail |
|---|---|
| **Date** | 2026-10-26 |
| **Type** | Procedure / Documentation |
| **Status** | **Documented** — reference guide with manifests, audit script, and visual diagrams; ready for execution |
| **Cluster** | lab.ocp.local (OCP 4.20.35, dev/testing) |
| **Scope** | Namespace-level compute, storage, and object-count governance: ResourceQuota, LimitRange defaults, OCP ClusterResourceQuota, quota scopes, and `exceeded quota` troubleshooting |
| **Why** | Day-to-day admin hit-list item ("ResourceQuota blocking deployment") plus the governance half of namespace onboarding: quotas are the bulkhead that stops one team's workload from sinking shared cluster capacity |

## TL;DR — the four-layer model

```
ClusterResourceQuota  (OCP only — one pool across N namespaces by label selector)
        │
ResourceQuota         (namespace ceiling — Σ requests/limits, storage, object counts)
        │
LimitRange            (per-object defaults + min/max — injects requests so quota admission passes)
        │
Pod requests/limits   (what the quota actually counts — NOT real usage)
```

**Golden rule:** a compute quota (`requests.cpu`/`memory`) makes requests **mandatory**
on every new pod. Ship a LimitRange with defaults alongside the quota, or every
developer pod without requests gets `403 Forbidden: exceeded quota`.

## Quick fix — "deployment blocked by quota"

```bash
# What hit the ceiling?
oc describe quota -n <target-namespace>          # compare hard: vs used:

# Then either:
# (a) right-size the workload's requests, or
# (b) raise the quota (with approval), or
# (c) clean up the consumer — stale pods / Released PVCs / object sprawl
```

Full decision tree (which resource hit, sync lag, missing requests) →
[ResourceQuota-Controls-Guide.md §7](ResourceQuota-Controls-Guide.md).

## Files

- [`ResourceQuota-Controls-Guide.md`](ResourceQuota-Controls-Guide.md) — full guide: enforcement flow, quota matrix, scopes, OCP ClusterResourceQuota, troubleshooting tree, GitOps pattern — with visual diagrams
- [🌐 `ResourceQuota-Controls-Guide.html` — open rendered](https://esarath.github.io/OCP_Issue-Fix_RCA/issues/33-resourcequota-controls/ResourceQuota-Controls-Guide.html) — standalone HTML (flat infographic SVG diagrams) · [`source`](ResourceQuota-Controls-Guide.html)
- [`manifests/resourcequota-compute.yaml`](manifests/resourcequota-compute.yaml) — standard compute + object-count quota
- [`manifests/limitrange-defaults.yaml`](manifests/limitrange-defaults.yaml) — matching LimitRange (default/defaultRequest/min/max)
- [`manifests/clusterresourcequota.yaml`](manifests/clusterresourcequota.yaml) — OCP multi-project quota by label selector
- [`manifests/quota-scopes-besteffort-ban.yaml`](manifests/quota-scopes-besteffort-ban.yaml) — scoped quota banning BestEffort pods
- [`scripts/quota-audit.sh`](scripts/quota-audit.sh) — read-only audit: every quota + % used, flags ≥80% (exit 1 = attention needed)

## Related

- **Issue 23** — PV/PVC Released-state cleanup (the storage half of "quota stuck high")
- **checklists/admin-user-onboarding.md** — namespace onboarding flow where quotas plug in
