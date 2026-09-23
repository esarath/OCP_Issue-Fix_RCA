# F5 BIG-IP Integration — CIS (Container Ingress Services) — OCP Side

How the cluster connects to an enterprise F5: **CIS is a controller pod that watches your manifests and programs the BIG-IP over its REST API.** CIS itself carries no traffic — it's pure control plane; the BIG-IP does all forwarding.

> Placeholders in `<angle brackets>` — replace before applying.

## Architecture — two planes

```
CONTROL PLANE   CIS pod ──HTTPS REST (AS3/iControl)──► BIG-IP mgmt :443
                Declares VIPs, pools, health monitors from CRDs

DATA PLANE      client ──► F5 VIP ──► pool members
                nodeport mode:  nodeIP:nodePort    (works with any CNI)
                cluster  mode:  podIP:podPort      (BIG-IP joins OVN via VXLAN)
```

| Mode | Pool members | Needs | Best for |
|---|---|---|---|
| `nodeport` | `workerIP:nodePort` | nothing extra | labs, simple setups |
| `cluster` (VXLAN) | pod IPs directly | BIG-IP license + tunnel into OVN overlay (CIS builds it via AS3) | direct-to-pod, per-pod health, no kube-proxy hop |

## Team split (RACI)

| Task | Owner |
|---|---|
| BIG-IP admin: partition `ocp_lab`, CIS service account, certs/licensure | Network/ADC team |
| CIS install + CRDs in cluster | Platform/OCP team |
| Per-app VIP/pool/monitor (`VirtualServer`/`TransportServer`) | App/platform team self-service |
| Health endpoint path | App team defines, CIS carries it to the F5 monitor |

## Step 1 — BIG-IP prep (request from network team)

- Partition: `ocp_lab` (CIS only writes inside it)
- REST service account, e.g. `svc-cis-ocp` (Resource Admin scoped to the partition)
- Hand you: mgmt URL, credentials, partition name

## Step 2 — Cluster-side install

```bash
oc new-project f5-cis

oc create secret generic bigip-login -n f5-cis \
  --from-literal=username=svc-cis-ocp \
  --from-literal=password='<password>'

# Deploy k8s-bigip-ctlr — via OLM operator or the Deployment in manifests/f5-cis/
oc apply -f manifests/f5-cis/cis-deployment.yaml
```

Key controller args (see manifest): `--bigip-url`, `--bigip-partition`, `--pool-member-type`, `--manage-routes=true` for native Route support, `--insecure` lab-only (mount the BIG-IP CA for prod).

## Step 3 — Expose apps (three API choices)

```yaml
# L7 — VirtualServer CRD (preferred)
apiVersion: cis.f5.com/v1
kind: VirtualServer
metadata: {name: myapp-vs, namespace: <app-ns>}
spec:
  host: myapp.lab.ocp.local
  virtualServerAddress: "192.168.29.80"     # VIP on BIG-IP
  pools:
    - path: /
      service: myapp
      servicePort: 8080
      monitor:                              # ★ same path as readinessProbe
        type: http
        send: "GET /readyz HTTP/1.0"
        interval: 10
        timeout: 31
---
# L4 — TransportServer (databases, arbitrary TCP/UDP)
apiVersion: cis.f5.com/v1
kind: TransportServer
metadata: {name: pg-ts, namespace: <ns>}
spec:
  virtualServerAddress: "192.168.29.81"
  virtualServerPort: 5432
  mode: tcp
  pool: {service: postgres, servicePort: 5432}
```

Third option: native `Route`/`Ingress` picked up automatically with `--manage-routes=true` (version-dependent — check CIS docs for the whitelist ConfigMap/annotations your release needs).

## Step 4 — Verify

```bash
oc logs -n f5-cis deploy/k8s-bigip-ctlr --tail=50    # AS3 push status
oc get virtualserver,transportserver -A              # Status: OK
# BIG-IP: partition ocp_lab shows VIP + pools green
curl -I http://myapp.lab.ocp.local                   # through the VIP
```

## Firewall / communication requirements

| Flow | Direction | Port |
|---|---|---|
| CIS → BIG-IP REST | workers → BIG-IP mgmt | tcp/443 |
| BIG-IP → pool members (nodeport) | F5 self-IPs → workers | tcp/30000-32767 (or svc nodePort) |
| BIG-IP → pod IPs (cluster mode) | VXLAN tunnel | udp/4789 + overlay config |

## Notes

- **Monitor alignment** is the Part-6 best practice applied at the F5: the monitor must test the same "can serve" endpoint as `readinessProbe` — never a deeper or shallower check.
- CIS partition is self-service: everything CIS manages lives under `ocp_lab`; network team's global config untouched.
- Lab has no F5 — this doc is the pattern for when one is introduced; svc-infra HAProxy plays the same Layer-3 role today.
