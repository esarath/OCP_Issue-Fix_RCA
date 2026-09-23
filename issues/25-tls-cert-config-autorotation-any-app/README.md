# Issue 25 — TLS Certificate Configuration & Auto-Rotation for Routes (Any App/DB)

| Field | Detail |
|---|---|
| **Date** | 2026-09-23 |
| **Type** | Procedure/Documentation — TLS cert setup + auto-rotation |
| **Status** | Documented — ready for manual execution |
| **Scope** | Any OpenShift Route (web apps, APIs, Jenkins) and database TLS — with Jenkins on `lab.ocp.local` as the worked example |
| **Cluster** | lab.ocp.local (OCP 4.20.35, dev/testing environment) |
| **Problem** | Route certs on the `.local` lab domain are hand-made and expire silently — no CA, no renewal automation |
| **Solution Documented** | Lab internal CA + edge-terminated route cert; auto-rotation via **cert-manager + openshift-routes** (Option A) or **openssl + cron rotation script** (Option B) |

---

## Why This Exists

- Cluster apps are exposed on `*.apps.lab.ocp.local` — a **`.local` domain**, so public CAs (Let's Encrypt etc.) **cannot** issue certs. Everything must come from an internal CA.
- The one cert on disk (`~/certificate/tls.crt`) is self-signed for `myapp-ssl.apps-crc.testing` — wrong CN, no SANs, unusable for `jenkins-jenkins.apps.lab.ocp.local`.
- Jenkins runs **plain HTTP/8080** in-cluster; TLS is terminated at the **router (edge termination)** — so cert management lives entirely on the Route object, not inside the app.
- External **HAProxy** on `svc-infra` (192.168.29.10) frontends some routes and currently serves HTTP only (`fix-jenkins-haproxy-nossl.sh`).

## Quick Path

| Want | Do |
|---|---|
| TLS on Jenkins today, rotate manually later | Part 1 + Part 2 of the [Guide](TLS-Cert-Auto-Rotation-Guide.md) |
| Set-and-forget rotation (recommended) | [Guide](TLS-Cert-Auto-Rotation-Guide.md) Part 4 Option A — cert-manager + `openshift-routes`; cert auto-injected into route, renewed at 1/3 lifetime |
| Rotation without installing anything | [Guide](TLS-Cert-Auto-Rotation-Guide.md) Part 4 Option B — `scripts/rotate-cert.sh` + cron/systemd |
| TLS for a database route | [Guide](TLS-Cert-Auto-Rotation-Guide.md) Part 6 — `passthrough`/`reencrypt` + service-CA pattern |

## Files

```
25-tls-cert-config-autorotation-any-app/
├── README.md                              # This file
├── TLS-Cert-Auto-Rotation-Guide.md        # Full step-by-step guide (any app/db)
├── manifests/
│   ├── jenkins.cnf                        # openssl CSR config (SANs)
│   ├── lab-ca-issuers.yaml                # selfsigned -> root CA -> CA ClusterIssuer
│   ├── route-tls-certmanager.yaml         # Route annotated for cert-manager injection
│   ├── cert-rotator-rbac.yaml             # SA + Role/RoleBinding for script rotation
│   └── jenkins-https-frontend.cfg         # HAProxy TLS frontend (svc-infra)
└── scripts/
    └── rotate-cert.sh                     # Option B: check expiry -> regen -> patch route
```

Working copies also live at `~/manifests/jenkins/`.
