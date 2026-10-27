# Issue 35 — Kubernetes Ingress: Advanced Routing (Host, Path, TLS & Production Patterns)

| Field | Detail |
|---|---|
| **Date** | 2026-10-27 |
| **Type** | Procedure / Documentation |
| **Status** | **Documented** — concept guide with visual diagrams; reference material |
| **Cluster** | lab.ocp.local (OCP 4.20.35, dev/testing) |
| **Scope** | Ingress vs Ingress Controller, request flow (DNS → LB → controller → Service → Pods), host-based / path-based / combined routing, TLS Secrets, NGINX install, production microservices example, advanced NGINX annotations (rewrite, rate limiting, auth, canary), Service vs Ingress, production checklist. Source: [DevOps.dev article](https://blog.devops.dev/kubernetes-ingress-advanced-routing-deep-dive-with-diagrams-production-patterns-57204ce40092) |

## TL;DR

```
Client → DNS → LoadBalancer IP → Ingress Controller (NGINX/Traefik/HAProxy)
       → rule match (host + path) → Service → Pods

Host-based   app.example.com → app-svc   |  api.example.com → api-svc
Path-based   example.com/app → app-svc   |  example.com/api → api-svc
TLS          kubectl create secret tls ... → spec.tls[].secretName
```

**Golden rule:** the Ingress resource is only a set of rules — *the Ingress Controller is what actually proxies the traffic.*

On this cluster, OpenShift's default router (HAProxy, `openshift-ingress`) acts as the Ingress Controller —
plain `Ingress` objects are converted into `Route`s automatically.

## Quick check

```bash
# upstream
kubectl get ingressclass
kubectl get ingress -A
kubectl describe ingress <name> -n <ns>
kubectl logs -n ingress-nginx deploy/ingress-nginx-controller

# OCP equivalent on lab.ocp.local
oc get ingresscontroller -n openshift-ingress-operator
oc get pods -n openshift-ingress -o wide
oc get ingress,route -n <target-namespace>
```

## Files

- [`Kubernetes-Ingress-Guide.md`](Kubernetes-Ingress-Guide.md) — full guide: Ingress vs controller, request flow, host/path/combined routing, TLS, NGINX install, production example, rewrite / rate limit / auth / canary, Service vs Ingress, checklist, commands — with PNG diagrams
- [🌐 `Kubernetes-Ingress-Guide.html` — open rendered](https://esarath.github.io/OCP_Issue-Fix_RCA/issues/35-kubernetes-ingress-advanced-routing/Kubernetes-Ingress-Guide.html) — standalone HTML (textbook-style inline SVG diagrams) · [`source`](Kubernetes-Ingress-Guide.html)
- [`diagrams/`](diagrams/) — each diagram as `.svg` + `.png` (Client → Ingress → Service → Pods style), reusable in slides/Confluence

## Related

- **Issue 34** — Kube-Proxy: how Service traffic finds the right pod (the layer below Ingress)
- **Issue 28** — Load balancer planning & design (Router/ingress layer on OCP)
- **Issue 25** — TLS certificate configuration & auto-rotation for Routes
