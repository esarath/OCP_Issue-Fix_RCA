# Issue 24 — Node Metrics Lost on worker-1: Stale Kubelet CA Bundle While CMO Is Unmanaged

| Field | Detail |
|---|---|
| **Date** | 2026-09-21 |
| **Type** | Incident RCA + Proposed Fix |
| **Status** | **DRAFT — pending customer approval; no remediation performed** |
| **Cluster** | lab.ocp.local (OCP 4.20.35, dev/testing) |
| **Symptom** | `oc adm top nodes` → worker-1 `<unknown>`; Prometheus kubelet targets down for worker-1 (all) and worker-2 (`/metrics`); `TargetDown` warnings firing |
| **Impact** | Monitoring blind spot only — no workload/control-plane impact. Spreads to masters as their kubelet certs renew (master-2 on **2026-09-25 14:10 UTC**) |
| **Root cause** | `openshift-monitoring/kubelet-serving-ca-bundle` is synced only by the Cluster Monitoring Operator. CMO has been stopped (ClusterVersion override) since 2026-09-17 to keep a replica pin (Issue 22), so the bundle froze on 2026-09-05. The 2026-09-20 signer rotation (`kube-csr-signer_@1789893034`) is not in it, so certs from the new signer are rejected (`x509: certificate signed by unknown authority`) |
| **Recommended fix** | Re-enable CMO and clear `ClusterVersion.spec.overrides` (also required before the 4.20.38 patch — `Upgradeable=False` while set). Cost: 5 monitoring components return to 2 replicas (+~1.4 GiB memory requests) |
| **Workaround** | Copy `openshift-config-managed/kubelet-serving-ca` into the monitoring ConfigMap, restart metrics-server and Prometheus. Recurs at every signer rotation (~15 d) |

## Quick fix (Option A)
```bash
oc scale deployment cluster-monitoring-operator -n openshift-monitoring --replicas=1
oc patch clusterversion version --type=merge -p '{"spec":{"overrides":[]}}'
```

## Files
- [`RCA.md`](RCA.md) — full root cause analysis, timeline, evidence, options, change plan, risks, approval block
- [`scripts/verify-kubelet-ca-bundle.sh`](scripts/verify-kubelet-ca-bundle.sh) — read-only drift/at-risk check (exit 1 = attention needed)

## Related
- Issue 22 — Monitoring Scaling Approaches (introduced the replica pin)
