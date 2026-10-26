# Issue 34 — Kube-Proxy: How Service Traffic Finds the Right Pod

| Field | Detail |
|---|---|
| **Date** | 2026-10-26 |
| **Type** | Procedure / Documentation |
| **Status** | **Documented** — concept guide with visual diagrams; reference material |
| **Cluster** | lab.ocp.local (OCP 4.20.35, dev/testing) |
| **Scope** | Pod networking → ephemeral pod IPs → Services (stable ClusterIP/DNS) → kube-proxy as the per-node plumbing (iptables/IPVS) that makes the Service IP real. Includes Deployment-style interview snapshot and the OVN-Kubernetes note (no classic kube-proxy on OCP) |

## TL;DR

```
Pod network      → every pod can reach every pod by IP
Pod IP recreate  → IP changes; direct connections break
Service          → stable ClusterIP + DNS (virtual object, no process)
kube-proxy       → per-node daemon; programs iptables/IPVS so
                   traffic to the Service IP lands on a backend pod
```

**Golden rule:** the Service is only an API object — *kube-proxy makes its IP real on every node.*

On this cluster (OVN-Kubernetes) there is no classic kube-proxy — `ovnkube-node` programs
OVS/OpenFlow rules doing the same Service IP → endpoint NAT.

## Quick check

```bash
# upstream
kubectl get pods -n kube-system -o wide | grep kube-proxy
kubectl get endpointslices -n <ns>

# OCP equivalent on lab.ocp.local
oc get pods -n openshift-ovn-kubernetes -o wide | grep ovnkube-node
oc get svc && oc get endpointslices -n <target-namespace>
```

## Files

- [`Kube-Proxy-Guide.md`](Kube-Proxy-Guide.md) — full guide: interview snapshot, pod networking, ephemeral IPs, Services, kube-proxy mechanics, traffic path, DaemonSet install, OVN note — with mermaid diagrams
- [`Kube-Proxy-Guide.html`](Kube-Proxy-Guide.html) — rendered standalone HTML (flat infographic SVG diagrams)

## Related

- **Issue 33** — ResourceQuota controls (the other half of multi-tenant cluster hygiene)
- **Issue 28** — Load balancer planning & design (Layer-4/Layer-7 traffic paths above Services)
