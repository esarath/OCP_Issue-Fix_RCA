# Issue 36 — What Happens When You Deploy: The Full Flow, Step by Step

| Field | Detail |
|---|---|
| **Date** | 2026-10-27 |
| **Type** | Concept / Documentation |
| **Status** | **Documented** — concept guide with visual diagrams; reference material |
| **Cluster** | lab.ocp.local (OCP 4.20.35, dev/testing) |
| **Scope** | `oc apply` → kube-apiserver (authN/authZ/RBAC, schema validation, SCC admission) → etcd → Deployment controller → ReplicaSet controller → Pending pods → scheduler (filter/score/bind) → kubelet + CRI-O (image pull, sandbox, mounts, entrypoint) → probes + CNI (OVN-K) + EndpointSlice → reconcile loop; `oc rollout` ReplicaSet swap; mental model; where it commonly breaks |

## TL;DR

```
You → API server → etcd (desired state)
                        ↓ watch
   Deployment ctrl → ReplicaSet ctrl → Pods (Pending)
                        ↓
                   Scheduler → binds pod → node
                        ↓
              Kubelet + CRI-O + CNI → container runs
                        ↓
              Probes pass → Endpoints → traffic
```

**Golden rule:** you declare what you want in etcd; controllers, the scheduler and kubelets make reality match it — and keep matching it forever.

## Quick check

```bash
oc get deploy,rs,pods -n <target-namespace> -o wide     # Deployment → ReplicaSet → Pods
oc describe pod <pod> -n <target-namespace>             # Events: FailedScheduling / ErrImagePull
oc get nodes                                            # NotReady nodes shrink scheduling choices
oc get csr | grep -i pending                            # kubelet cert issues (pod Pending with node set)
oc get endpointslices -n <target-namespace>             # Ready pods appear here
oc rollout status deploy/<name> -n <target-namespace>
oc rollout undo   deploy/<name> -n <target-namespace>
```

## Files

- [`Deployment-Flow-Guide.md`](Deployment-Flow-Guide.md) — full guide in order: restaurant analogy, Steps 1–8, `oc rollout`, mental model, where it breaks — with PNG diagrams
- [🌐 `Deployment-Flow-Guide.html` — open rendered](https://esarath.github.io/OCP_Issue-Fix_RCA/issues/36-deployment-flow-apply-to-running/Deployment-Flow-Guide.html) — standalone HTML (colour-coded inline SVG diagrams) · [`source`](Deployment-Flow-Guide.html)
- [`diagrams/`](diagrams/) — each diagram as `.svg` + `.png`

## Related

- **Issue 06** — `master-2` transient NotReady (why NotReady nodes leave pods Pending)
- **Issue 07** — recurring kubelet cert expiry (pod Pending with a node assigned)
- **Issue 17** — local registry + cluster trust (image pull path used in Step 6)
- **Issue 34** — kube-proxy: how Service traffic reaches the pod after Step 7
- **Issue 35** — Kubernetes Ingress: routing external traffic to Services
