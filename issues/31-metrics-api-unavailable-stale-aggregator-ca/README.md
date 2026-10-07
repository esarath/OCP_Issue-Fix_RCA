# Issue 31 — Metrics API Down Cluster-Wide: Stale Aggregator CA Bundle While CMO Is Unmanaged

| Field | Detail |
|---|---|
| **Date** | 2026-10-07 |
| **Type** | Incident RCA + Executed Fix |
| **Status** | **Resolved** — fix applied and verified on the live cluster |
| **Cluster** | lab.ocp.local (OCP 4.20.35, dev/testing) |
| **Symptom** | `metrics.k8s.io/v1beta1: the server is currently unable to handle the request` on any `oc`/`kubectl` call that touches API discovery; `oc adm top` fully broken; `APIService v1beta1.metrics.k8s.io` = `False (FailedDiscoveryCheck)` |
| **Impact** | Metrics API completely unavailable cluster-wide: no `oc adm top`, no HPA metrics feed, no console utilization graphs. No workload/control-plane impact — nodes stayed Ready, operators Available |
| **Root cause** | Same root cause as Issue 24, different trust chain. The `aggregator-client-signer` rotated on 2026-09-28 (`@1790604083`, SKID `DE:A9:A6:5A…`), but the CA-bundle secret mounted by metrics-server (`metrics-server-92qmguums1qi8`) was last synced ~2026-09-10 — because the Cluster Monitoring Operator was still scaled to 0 + `unmanaged` (the Issue 22/24 change had never been reverted). kube-apiserver began presenting a proxy cert from the new signer on 2026-09-30 → `x509: certificate signed by unknown authority` → `FailedDiscoveryCheck`. Second defect: the `metrics-client-certs` scrape cert (Prometheus → metrics-server `/metrics`) expired 2026-09-25 and was never re-minted |
| **Fix applied** | 1) Patched `metrics-server-92qmguums1qi8` with the current `client-ca-file` + `requestheader-client-ca-file` from `kube-system/extension-apiserver-authentication`. 2) Re-minted `metrics-client-certs` via a `kubernetes.io/kube-apiserver-client` CSR + admin approve. 3) `oc scale deploy/cluster-monitoring-operator -n openshift-monitoring --replicas=1`. 4) Removed the `ClusterVersion.spec.overrides` entry so CMO is fully managed again |
| **Recurrence** | **Automatic** — with CMO running and managed, it re-generates the bundle secret at every signer rotation (~14–15 days) and re-mints the scrape cert before expiry. Verified live: within ~30s of CMO starting it created `metrics-server-824e055j4ou3h` and repointed the deployment |

## Quick fix (if this recurs while CMO is down)

```bash
# Refresh the aggregator-trust bundle metrics-server uses
oc get cm extension-apiserver-authentication -n kube-system -o yaml   # source of truth
oc patch secret <metrics-server-*> -n openshift-monitoring --type=merge \
  -p '{"data":{"requestheader-client-ca-file":"<b64>","client-ca-file":"<b64>"}}'
# Then the real fix:
oc scale deployment cluster-monitoring-operator -n openshift-monitoring --replicas=1
oc patch clusterversion version --type=merge -p '{"spec":{"overrides":[]}}'
```

## Files

- [`RCA.md`](RCA.md) — full root cause analysis, timeline, evidence, executed change record, preventive actions
- [`scripts/verify-metrics-api-trust.sh`](scripts/verify-metrics-api-trust.sh) — read-only health check: APIService state, bundle drift vs source, scrape-cert expiry, CMO managed state (exit 1 = attention needed)

## Related

- **Issue 24** — Stale `kubelet-serving-ca-bundle` while CMO unmanaged (the scrape/kubelet trust chain; same root cause, predicted this class of failure)
- **Issue 22** — Monitoring replica pin (the change that stopped CMO)
