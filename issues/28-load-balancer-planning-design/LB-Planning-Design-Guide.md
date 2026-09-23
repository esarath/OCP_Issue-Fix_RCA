# Load Balancer Planning & Design — Traffic Distribution & External Exposure on OpenShift

Requirement-driven design for: **distribute traffic across pods + expose services externally**, using Ingress Controllers (HAProxy/NGINX/F5/AVI), enterprise L4/L7 LBs at the edge, and MetalLB/cloud LBs for bare-metal — with health checks aligned to Kubernetes probes.

> **Placeholder convention** (repo-wide): anything in `<angle brackets>` is a placeholder.

---

## Table of Contents

1. [Requirements → the four LB layers](#part-0--requirements--the-four-lb-layers)
2. [Design decisions up front](#part-1--design-decisions-up-front)
3. [Layer 1 — in-cluster pod balancing](#part-2--layer-1--in-cluster-pod-balancing)
4. [Layer 2 — L7 ingress controllers](#part-3--layer-2--l7-ingress-controllers)
5. [Layer 3 — external LB integration](#part-4--layer-3--external-lb-integration)
6. [Layer 4 — MetalLB / cloud LB for L4 services](#part-5--layer-4--metallb--cloud-lb-for-l4-services)
7. [★ Best practice — align LB health checks with probes](#part-6---best-practice--align-lb-health-checks-with-probes)
8. [HA & capacity planning](#part-7--ha--capacity-planning)
9. [Security & TLS design](#part-8--security--tls-design)
10. [Implementation runbook for this cluster](#part-9--implementation-runbook)
11. [Validation & troubleshooting](#part-10--validation--troubleshooting)

---

## Part 0 — Requirements → the four LB layers

"Distribute traffic across pods and expose services externally" decomposes into four layers. Each has a different owner, health model, and failure domain — design each deliberately:

| Layer | Question it answers | This cluster's implementation | Alternatives |
|---|---|---|---|
| **1. Pod balancing** (east-west) | Which ready pod gets the request? | `Service` (ClusterIP) + kube-proxy/IPTables — endpoints driven by **readiness probes** | headless Service, service mesh (istio) |
| **2. L7 ingress** (north-south, HTTP/S) | Which app/route does this request belong to? | **OpenShift Router** (HAProxy) — IngressController `default`, HostNetwork on workers :80/:443 | NGINX IC, F5 CIS, AVI/NSX-T |
| **3. External edge LB** | Which router/ingress endpoint is alive? | **svc-infra HAProxy** VIP `192.168.29.10` → worker IPs | F5 BIG-IP, AVI, NetScaler, keepalived pair |
| **4. L4 service exposure** (non-HTTP) | How does TCP/UDP traffic on arbitrary ports get a stable external IP? | **MetalLB** L2 (pool `192.168.29.70-90`) → `type: LoadBalancer` | BGP mode, cloud LB (AWS/Azure/GCP) |

```
                        ┌──────────────────────────────────────────────┐
 clients ──DNS──► svc-infra HAProxy VIP (192.168.29.10)     Layer 3 ─ edge
                        │  :6443 → masters (API)   :80/:443 → workers
                        ▼
              Router pods (HAProxy) on worker-1/worker-2    Layer 2 ─ L7 ingress
                        │  SNI/host → route → service
                        ▼
              Service (ClusterIP) → ready pod endpoints     Layer 1 ─ kube-proxy
                        ▲
   MetalLB VIP :5432 ───┘ (L4, non-HTTP, bypasses router)   Layer 4 ─ any port
```

---

## Part 1 — Design decisions up front

| Decision | Options | This design | Why |
|---|---|---|---|
| L7 termination point | Router edge / reencrypt / passthrough | **edge** (per Issue 25) | Cert ops stay on the Route object; pods stay HTTP |
| External LB mode for apps | L4 tcp-pipe vs L7 http | **L4 tcp-pipe** to workers | Router owns host/SNI routing — don't duplicate L7 logic at the edge |
| API LB | Required on UPI — no alternative | HAProxy :6443 → 3 masters | Installer needs it before cluster exists |
| L4 app exposure | MetalLB L2 vs BGP vs NodePort | **L2** (flat lab net) | Zero router dependencies; BGP needs a peering-capable switch we don't have |
| Source IP preservation | PROXY protocol / externalTrafficPolicy | `Local` on LB services; PROXY optional at edge | See Part 4.4 — decide per-service |
| Health model | LB checks vs k8s probes | **Aligned** — Part 6 | The stated best practice; prevents blackhole traffic |

---

## Part 2 — Layer 1: in-cluster pod balancing

Already built-in — but its health semantics drive everything above it.

| Type | Use for | External? |
|---|---|---|
| `ClusterIP` (default) | Every internal service | No — cluster-only |
| `NodePort` | Building block; rarely used directly on OCP | Node IP:30000-32767 — avoid for prod exposure |
| `LoadBalancer` | L4 external IP via MetalLB/cloud | Yes — Part 5 |
| `ExternalName` | DNS alias to outside host | N/A |
| Headless (`clusterIP: None`) | Stateful sets needing per-pod DNS (DBs, Kafka) | No — client does its own balancing |

**The load-balancing unit is the *endpoint*, and endpoints are fed exclusively by `readinessProbe`.** A pod without a readiness probe is considered ready the instant it starts — it receives traffic while still booting. This is the root of most "intermittent 503s on rollout" issues and the reason Part 6 exists.

```bash
# What's actually being balanced (only READY pods appear)
oc get endpoints <svc> -n <ns>
oc get endpointslices -l kubernetes.io/service-name=<svc> -n <ns>
```

---

## Part 3 — Layer 2: L7 ingress controllers

### 3.1 The field

| Controller | Model on OCP | Strengths | Trade-offs |
|---|---|---|---|
| **OpenShift Router (HAProxy)** — *ours* | Built-in IngressController, Route API | Zero-install, route sharding, integrated TLS/reencrypt/passthrough, operator-managed | HAProxy-specific tuning only; Route ≠ Ingress API (portability) |
| **NGINX Ingress Controller** | Community/Plus via OLM or helm | Standard `Ingress` API, huge feature surface, rate-limit/auth snippets | Separate lifecycle; you own its HA/tuning |
| **F5 Container Ingress Service (CIS)** | F5 pods + BIG-IP offload | Enterprise BIG-IP feature parity, AS3 declarative, hardware SSL | Needs licensed BIG-IP; BIG-IP becomes the dataplane |
| **AVI / NSX-T ALB** | AKO (Avi Kubernetes Operator) | Elastic service engines, analytics, WAF, L4+L7 | Requires AVI controller infra; best with NSX-T/VCF |

**Design rule for this cluster:** use the built-in Router for HTTP(S) — it's already HA across both workers. Add a second controller only when you need Ingress-API portability, per-app WAF snippets, or to front non-Route traffic patterns.

### 3.2 Router design on this cluster

- `endpointPublishingStrategy: HostNetwork` — each worker's real IP serves :80/:443; the external LB (Layer 3) points at worker IPs. No extra hop.
- `replicas: 2` — one per worker (`manifests/ingresscontroller-tuning.yaml`). Router anti-affinity is automatic (router pods won't colocate).
- **Sharding** (optional): create additional IngressControllers with `routeSelector`/`namespaceSelector` to split prod vs dev apps onto separate router pools/VIPs.

```bash
oc get ingresscontroller -n openshift-ingress-operator
oc get pods -n openshift-ingress -o wide        # router pods on workers
```

---

## Part 4 — Layer 3: external LB integration

### 4.1 What the external LB must carry (UPI)

| Frontend | Port | Backends | Mode | Purpose |
|---|---|---|---|---|
| API | 6443 | masters .21/.22/.23 | tcp | `api.lab.ocp.local` — cluster API + `oc` clients |
| MCS | 22623 | masters | tcp | Ignition configs for new/scaling nodes |
| Apps HTTP | 80 | workers .31/.32 | tcp | `*.apps.lab.ocp.local` → router |
| Apps HTTPS | 443 | workers | tcp | SNI passes to router (edge TLS lives there) |

`manifests/external-haproxy-lb.cfg` implements exactly this — it mirrors what the installer required at Day-0 and keeps app traffic flowing to the router layer.

### 4.2 DNS design

```
api.lab.ocp.local          A    192.168.29.10      # -> API frontend
api-int.lab.ocp.local      A    192.168.29.10      # internal API alias
*.apps.lab.ocp.local       A    192.168.29.10      # wildcard -> app frontends
<metallb-svc>.lab.ocp.local A   192.168.29.7x      # per-LB-service records
```

Wildcard DNS → the VIP means **new routes need zero DNS/LB work** — the biggest operational win of this pattern.

### 4.3 Enterprise L4/L7 patterns (F5/AVI/NGINX at the edge)

Three ways enterprise LBs integrate — pick per your infra:

| Pattern | How | When |
|---|---|---|
| **Dumb L4 pipe** *(this cluster)* | LB → router endpoints; all L7 logic stays in the router | Simplest; LB team owns only health+VIP |
| **LB-native ingress** (F5 CIS, AVI AKO) | LB data plane *is* the ingress — routes/Ingress CRs program it directly | When the enterprise mandates BIG-IP/AVI features (WAF, SSL offload, analytics) |
| **Two-tier** | Enterprise LB → NGINX/Router → services | Large orgs: DMZ LB for edge policy + in-cluster L7 for app routing |

### 4.4 Source IP preservation — decide deliberately

| Hop | Default behavior | To preserve client IP |
|---|---|---|
| External LB → router (tcp mode) | Source = VIP | HAProxy `send-proxy` + router `endpointPublishingStrategy...protocol: PROXY` |
| Router → pod (edge) | Source = router pod IP | Router sets `X-Forwarded-For` — app must read it (Jenkins does) |
| MetalLB service → pod | Source NAT by kube-proxy | `externalTrafficPolicy: Local` (real client IP; trade-off: only nodes hosting pods answer — health becomes per-node) |

> Gotcha: `externalTrafficPolicy: Local` + MetalLB L2 means the node holding the VIP must also hold a ready pod, or traffic drops. For multi-node-balanced L4, use `Cluster` policy and accept SNAT, or BGP with `Local` + pod anti-affinity.

---

## Part 5 — Layer 4: MetalLB / cloud LB for L4 services

For anything that isn't HTTP(S) — Postgres, MySQL, Redis, JNLP agents, MQTT, game servers — Routes don't apply. `type: LoadBalancer` gets a real IP.

### 5.1 MetalLB modes

| Mode | How it works | Needs | Lab fit |
|---|---|---|---|
| **L2** *(ours)* | One node ARPs for the VIP; failover moves it to another node (~seconds) | IPs on node subnet, free range | ✅ flat 192.168.29.0/24 |
| **BGP** | Every node peers with ToR; ECMP spreads flows | BGP-capable upstream router, ASNs | Not available — keep for reference |

Live state: pool `redis-test-pool` `192.168.29.70-90` + `L2Advertisement` — `manifests/metallb-config.yaml` generalizes it.

### 5.2 Pool design rules

- Carve a **dedicated range** outside DHCP and outside the svc-infra VIP (`192.168.29.10`) and node IPs
- One pool per environment (`lab-services-pool`, `prod-pool`) so `L2Advertisement`/`BGPAdvertisement` can scope which nodes announce them
- Pin important services with `loadBalancerIP:` — DHCP for infra IPs is a foot-gun
- `autoAssign: false` on pools meant for production — forces explicit, documented IP requests

### 5.3 When LoadBalancer is the right answer (and when it isn't)

| Workload | Right exposure | Why |
|---|---|---|
| Web UI / REST / Jenkins | **Route** | TLS, host routing, cert automation — all free |
| Postgres/MySQL to outside | **LoadBalancer + passthrough TLS in app** | Arbitrary port, protocol-agnostic |
| JNLP/inbound agents (port 50000) | **LoadBalancer** | Raw TCP |
| Internal-only service | ClusterIP | Don't burn external IPs |

Cloud equivalents (for portability of this doc): AWS → NLB/ELB via cloud provider integration; Azure → Azure LB (same `type: LoadBalancer`); GCP → Google LB. The Service spec is identical — only the provisioner changes.

---

## Part 6 — ★ Best practice: align LB health checks with probes

This is the requirement's headline best practice — here's the full contract and how to implement it.

### 6.1 The probe contract

| Probe | K8s uses it for | LB-relevant effect |
|---|---|---|
| `startupProbe` | "Is it still booting?" — gates the other two | Prevents liveness-kill during slow starts (Jenkins/JVM) |
| `readinessProbe` | "Can it take traffic?" → **removes pod from Service endpoints** | **THE signal every LB layer ultimately follows** — router, kube-proxy, MetalLB all route only to ready endpoints |
| `livenessProbe` | "Is it wedged?" → container restart | Indirect: a restarting pod fails readiness anyway |

**Rule: external/LB health checks should test the same "can serve traffic" semantics as readiness — never liveness.** Checking a deeper or different path at the LB than the app uses for readiness produces split-brain health (LB thinks up, k8s thinks down → blackhole; or the reverse).

### 6.2 Alignment per layer

| Layer | Health mechanism | Align to readiness by |
|---|---|---|
| Service/endpoints | EndpointSlice membership | Automatic — it IS the readiness result |
| Router (HAProxy) | Router re-reads endpoints; backends only get ready pods | Automatic; route-level `haproxy.router.openshift.io/haproxy.health.check.interval` annotations for finer checks |
| svc-infra HAProxy → workers | `check` / `option httpchk` | Check that the **router process** is serving (:80/:443 responds, or router's `:1936` healthz if exposed) — NOT a specific app's readiness; app readiness is the router's job |
| MetalLB | Speaker advertises VIP while ≥1 ready endpoint (with `Local`: only on nodes hosting ready pods) | Automatic — `externalTrafficPolicy` decides the topology |
| Cloud LB (AWS/Azure/GCP) | Target-group health check path/port | Point the target check at the **same path/port as readinessProbe** (`/readyz` on the service port), not `/` or TCP-only |

### 6.3 The drain sequence — why probe alignment prevents dropped traffic

When a pod is killed (rollout, scale-down, drain):

```
1. Pod gets SIGTERM (preStop hook runs — sleep/app shutdown)
2. Pod marked unready -> leaves Service endpoints    ← kube-proxy, router stop NEW traffic
3. Endpoint removal propagates to LBs (~seconds — the gap preStop covers)
4. In-flight requests drain during terminationGracePeriodSeconds
5. SIGKILL after grace period
```

If the app exits instantly on SIGTERM **before** endpoints propagate (step 3), every LB in the chain still has it as a healthy backend → dropped requests. The `preStop: sleep 5` in `manifests/probe-aligned-deployment.yaml` exists precisely to out-wait propagation.

### 6.4 Anti-patterns this prevents

| Anti-pattern | Symptom | Fix |
|---|---|---|
| No readinessProbe | 503s on rollout — LB sends to booting pods | Add readiness (Part 6.2) |
| Deep liveness (checks DB) | Mass restart-loop when DB blips — whole service drops | Liveness = shallow process check only |
| LB checks `/` but readiness is `/readyz` | Split-brain health | Same path/port both places |
| Missing preStop | 502s during every scale-down | `preStop sleep` ≥ endpoint propagation time |
| `terminationGracePeriodSeconds: 5` on a slow app | In-flight long requests killed | Size it to your slowest legit request |

### 6.5 Audit it

```bash
./scripts/lb-health-check.sh     # flags every deployment lacking readinessProbe
```

---

## Part 7 — HA & capacity planning

| Component | Count | Placement | Failure math |
|---|---|---|---|
| Router pods | 2 | 1 per worker (auto anti-affinity) | 1 worker loss → external LB re-targets the other; routes unaffected |
| svc-infra HAProxy | 1 VIP | Single VM — **single point of failure** | For real HA: 2×HAProxy + keepalived VIP; lab tolerates the SPOF |
| MetalLB speaker | DaemonSet, all nodes | VIP lives on one node at a time (L2) | Node death → VIP moves in seconds; **concurrent TCP connections drop** on failover (L2 limit) |
| API LB backends | 3 masters | roundrobin | Survives 2 master failures for LB purposes (etcd quorum is the real floor — Issue 27) |
| App pods | ≥2 + `topologySpreadConstraints` | Spread across workers | Never run LB-fronted workloads at 1 replica |

Capacity rules of thumb: router ≈ HAProxy — a pod per worker handles tens of thousands of concurrent connections; size by **connection count and TLS handshakes**, not throughput. Watch `router_http_requests_total` / HAProxy stats (`:1936/metrics`).

---

## Part 8 — Security & TLS design

- **Termination decision** lives at the Route (Issue 25): `edge` for web apps, `passthrough` for DBs/apps owning TLS, `reencrypt` only when transit encryption to the pod is mandated
- External LB stays **L4/tcp** for `:443` — TLS and SNI belong to the router; don't double-terminate at svc-infra unless the edge LB must inspect (then it needs certs + becomes L7, a different design)
- **PROXY protocol** (Part 4.4) if real client IPs must survive the edge hop — enable on both ends or neither (mismatched PROXY = connection garbage)
- MetalLB VIPs are plain TCP — TLS is the **app's** job behind them (issue a cert per Part 6.2 of Issue 25's DB section)
- `InsecureEdgeTerminationPolicy: Redirect` everywhere — never `Allow` for external apps

---

## Part 9 — Implementation runbook (this cluster)

Ordered steps — most are already true; verify, don't assume:

```bash
# 1. Router health — replicas on both workers
oc get ingresscontroller default -n openshift-ingress-operator
oc get pods -n openshift-ingress -o wide                    # 1 pod per worker

# 2. External LB config — deploy external-haproxy-lb.cfg on svc-infra
scp manifests/external-haproxy-lb.cfg core@192.168.29.10:/etc/haproxy/conf.d/
ssh core@192.168.29.10 'haproxy -c -f /etc/haproxy/haproxy.cfg && systemctl reload haproxy'

# 3. DNS — confirm the three records exist (Part 4.2)
dig api.lab.ocp.local +short; dig anything.apps.lab.ocp.local +short

# 4. MetalLB — live already; extend the pool per manifests/metallb-config.yaml if needed
oc get ipaddresspool,l2advertisement -n metallb-system

# 5. For each app — apply the probe-aligned pattern
oc apply -f manifests/probe-aligned-deployment.yaml   # template — fill placeholders

# 6. Audit
./scripts/lb-health-check.sh
```

---

## Part 10 — Validation & troubleshooting

### Validation

```bash
# End-to-end through every layer
curl -I http://<app>-<ns>.apps.lab.ocp.local            # VIP -> router -> svc -> pod
oc get endpoints <svc> -n <ns>                          # only READY pods listed
oc get svc -A | grep LoadBalancer                       # MetalLB-assigned EXTERNAL-IP

# Failover: cordon a worker — router traffic must continue via the other
oc adm cordon <worker-1> && oc get pods -n openshift-ingress -o wide
curl -I http://<app>.apps.lab.ocp.local                 # still 200 via worker-2
oc adm uncordon <worker-1>

# Drain test: scale a 2-replica app to 1 while hammering it — zero 5xx expected
```

### Troubleshooting

| Symptom | Layer | Check |
|---|---|---|
| 503 from route | 1/2 | `oc get endpoints <svc>` — pods unready? Check readinessProbe |
| `curl` to VIP times out, route works internally | 3 | svc-infra `haproxy` backend state (`show stat` socket); worker :80/:443 listening |
| LoadBalancer EXTERNAL-IP `<pending>` | 4 | `oc get ipaddresspool`; pool exhausted? `oc logs -n metallb-system -l component=controller` |
| VIP answers but connection resets | 4 | `externalTrafficPolicy: Local` + VIP node has no ready pod |
| Intermittent 502 only during deploys | 6 | Missing preStop / readiness — Part 6.3/6.4 |
| Client IP shows as LB/router IP | 4.4 | PROXY protocol or `externalTrafficPolicy` decision needed |
| TLS handshake fails at VIP | 8 | Something terminating TLS at edge that shouldn't — keep :443 tcp |

---

## Decision recap

```
HTTP/HTTPS app?              → Route on the OCP Router (L7) — always
Non-HTTP external port?      → MetalLB LoadBalancer service (L4)
Need stable VIP for cluster? → svc-infra HAProxy (edge, L4 pipe to routers)
Enterprise LB mandated?      → F5 CIS / AVI AKO pattern (Part 4.3)
Any exposure?                → readinessProbe required; LB checks aligned to it (Part 6)
```
