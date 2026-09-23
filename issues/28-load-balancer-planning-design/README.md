# Issue 28 — Load Balancer Planning & Design (Pod Traffic Distribution + External Exposure)

| Field | Detail |
|---|---|
| **Date** | 2026-09-23 |
| **Type** | Architecture/Design document + implementation guide |
| **Status** | Documented — ready for review/execution |
| **Scope** | All four LB layers: in-cluster pod balancing (Service), L7 ingress (Router/Ingress Controllers), external enterprise L4/L7 LB, bare-metal L4 (MetalLB) |
| **Cluster** | lab.ocp.local (OCP 4.20.35, UPI/Proxmox — 3 masters + 2 workers, svc-infra HAProxy at 192.168.29.10, MetalLB L2 pool 192.168.29.70-90 already deployed) |
| **Purpose** | Distribute traffic across pods and expose services externally, per enterprise LB pattern |
| **Key best practice applied** | Align LB health checks with Kubernetes readiness/liveness probes — see Guide Part 6 |

---

## Why This Exists

"Load balancer" on OCP is four different layers that are easy to conflate. Picking the wrong one (e.g. LoadBalancer service for a web app, or NodePort for a database) costs you TLS termination, source-IP visibility, or availability. This doc maps the requirement → the right layer → the concrete config on this cluster.

## The four layers at a glance

```
Layer 1  Pod balancing (east-west)     Service ClusterIP — kube-proxy, no config needed
Layer 2  L7 HTTP(S) ingress (north-south)  OpenShift Router (HAProxy) on workers :80/:443
Layer 3  External L4/L7 LB (edge)      svc-infra HAProxy → router IPs (or enterprise F5/AVI/NGINX)
Layer 4  Raw L4 service exposure       MetalLB LoadBalancer IPs (192.168.29.70-90) — TCP/UDP, any port
```

## Quick Path

| Need | Use | Guide section |
|---|---|---|
| Web app / API / Jenkins | **Route** on the OCP Router (L7, TLS, edge) | Part 4.1 |
| Non-HTTP port to outside (DB, MQTT, agent JNLP) | **MetalLB LoadBalancer** service | Part 5 |
| HA for the router itself | **svc-infra HAProxy** VIP → worker router endpoints | Part 4.2 + `manifests/external-haproxy-lb.cfg` |
| Enterprise integration (F5/AVI/NGINX) | Ingress controller or ingress-lb pattern | Part 4.3 |
| Zero dropped connections on rollout/scale-down | Probe-aligned LB + preStop draining | Part 6 |

## Files

```
28-load-balancer-planning-design/
├── README.md                               # This file
├── LB-Planning-Design-Guide.md             # Full design + implementation doc
├── manifests/
│   ├── external-haproxy-lb.cfg             # svc-infra: API:6443 + MCS:22623 + apps:80/443 frontends
│   ├── metallb-config.yaml                 # IPAddressPool + L2Advertisement + sample LB service
│   ├── ingresscontroller-tuning.yaml       # router replicas/strategy/tuning patch
│   └── probe-aligned-deployment.yaml       # reference app: probes + preStop + graceful shutdown
└── scripts/
    └── lb-health-check.sh                  # audit: probe alignment + router/LB/backend health
```
