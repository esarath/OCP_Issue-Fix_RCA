# Kube-Proxy in Kubernetes — How Service Traffic Finds the Right Pod

| Field | Detail |
|---|---|
| **Document status** | **DOCUMENTED** — concept/reference guide |
| **Cluster** | lab.ocp.local — OpenShift 4.20.35 (OVN-Kubernetes) |
| **Category** | Kubernetes networking — Services & node-level routing |
| **Audience** | OCP/K8s administrators, platform engineers |

> 📄 Companion visual doc: [`Kube-Proxy-Guide.html`](Kube-Proxy-Guide.html) — same content with flat infographic-style diagrams.

---

## 0. Interview Snapshot — The 60-Second Story

> *"Pod IPs are ephemeral — recreate a pod and it comes back with a different address, so
> hard-coding pod IPs between apps breaks on every rollout. A Kubernetes Service fixes that with
> a stable IP and DNS name. But here's the part people miss: **the Service isn't a process** —
> nothing listens on that IP. The actual forwarding is done by **kube-proxy**, which runs on
> every node and programs iptables/IPVS rules so traffic to the Service IP lands on a healthy
> backend pod. Service = stable address; kube-proxy = the plumbing that makes the address real."*

**Quotable lines worth stealing:**

- "The Service is just an API object — **kube-proxy makes its IP real** on every node."
- "Pod IPs are like hotel room numbers — fine for a stay, useless as a home address."
- "Traffic never hits a Service 'process' — iptables rewrites it to a pod before it leaves the node."
- "kube-proxy is a DaemonSet because the routing table has to exist **wherever traffic originates**."

**One-liner:** *"The Service is the stable address on the envelope — kube-proxy is the post
office on every node that actually delivers it."*

---

## 1. Pod Networking — Every Pod Can Reach Every Pod

First rule of Kubernetes networking: **every Pod should be able to communicate with every other
Pod**, even across nodes. The Pod network provides an internal virtual network spanning the
whole cluster.

A web app on Node 1 (`10.32.0.10`) can reach a database on Node 2 (`10.32.0.15`) — directly,
by pod IP.

```mermaid
flowchart TB
    subgraph CP["☸ Control Plane — apiserver · scheduler · controller-mgr · etcd"]
    end
    subgraph CL["Pod Network — internal virtual network across the cluster"]
        subgraph N1["Node 1 — Worker"]
            WA["🌐 Web App Pod<br/>10.32.0.10"]
        end
        subgraph N2["Node 2 — Worker"]
            DB["▤ Database Pod<br/>10.32.0.15"]
        end
        WA <-->|"Pod-to-Pod"| DB
    end
    CP -.-> N1
    CP -.-> N2
```

---

## 2. But Pod IP Addresses Are Not Permanent

A pod is not a permanent server. Recreate it — the new pod gets a **different IP**. If the web
app hard-coded `10.32.0.15`, it breaks the moment the database pod is recreated:

```mermaid
flowchart LR
    subgraph P1["1 — initial state"]
        A["web 10.32.0.10"] -->|"ok"| B["db 10.32.0.15"]
    end
    subgraph P2["2 — db recreated"]
        A2["web 10.32.0.10"] -->|"ok"| B2["NEW db 10.32.0.27"]
        B1["old db 10.32.0.15 ✗"]
    end
    subgraph P3["3 — old IP dead"]
        A3["web 10.32.0.10"] -.->|"still targets .15 — FAILS ✗"| B3["db 10.32.0.27"]
    end
    P1 --> P2 --> P3
    style B1 fill:#f8d8d4,stroke:#e74c3c
```

> ⚠️ Relying on Pod IPs directly is not reliable. This is why **Services** exist.

---

## 3. Using a Service Instead of the Pod IP

Create a **Service** for the database. The app connects to the name `db` — a stable ClusterIP
and DNS name that survives every recreate:

```mermaid
flowchart TB
    subgraph CL["Kubernetes Cluster"]
        SVC["⛭ DB Service — `db`<br/>ClusterIP 10.96.0.50 (stable)"]
        subgraph N1["Node 1"]
            WA["Web App Pod<br/>10.32.0.10"]
        end
        subgraph N2["Node 2"]
            DB["Database Pod<br/>10.32.0.15 — IP may change"]
        end
        WA -->|"connects to Service (db)"| SVC
        SVC --> DB
    end
```

| Approach | On pod recreate |
|---|---|
| Direct Pod IP | ✗ app breaks — old IP dead |
| Via Service | ✓ app never notices — Service IP stays |

---

## 4. So Where Does the Service Actually Run?

A Service has an IP — `10.96.0.50`. Does it join the pod network? Run as a container?

> **No — and this is the important concept.** A Service is **not a pod, not a container, not a
> process**. It's a *virtual component* — an API object inside the Kubernetes system. Nothing
> "sits" on `10.96.0.50`.

So how does traffic to that IP reach a backend pod? → **kube-proxy**.

---

## 5. What Is kube-proxy?

**kube-proxy is a process that runs on every node.** It watches the API server for Service and
EndpointSlice changes, then configures the node's networking so traffic to a Service IP reaches
the right backend pods — via **iptables** or **IPVS** rules.

```mermaid
flowchart TB
    SVC["⛭ DB Service — db · 10.96.0.1"]
    subgraph N1["Node 1"]
        KP1["⚙ kube-proxy"] --> P1["Database Pod<br/>10.32.0.15"]
    end
    subgraph N2["Node 2"]
        KP2["⚙ kube-proxy"] --> P2["Database Pod<br/>10.32.0.27"]
    end
    SVC -->|"watches svc + endpoints,<br/>programs node rules"| KP1
    SVC --> KP2
    style SVC fill:#1a6fd4,color:#fff
```

| kube-proxy responsibility | Detail |
|---|---|
| Runs on every node | DaemonSet in `kube-system` (upstream) / platform-managed on OCP |
| Watches the API server | Service & EndpointSlice changes trigger rule updates |
| Programs node rules | iptables / IPVS: Service IP → backend pods |
| Routes + load balances | Forwards to one healthy backend pod |

---

## 6. How kube-proxy Forwards Service Traffic

Service `db` = `10.96.0.1`; backend pod = `10.32.0.15`. When the web app sends to `10.96.0.1`:

```mermaid
sequenceDiagram
    participant WA as Web App Pod (Node 1)
    participant KP as kube-proxy (Node 1)
    participant SVC as Service db (10.96.0.1)
    participant DB as Database Pod 10.32.0.15 (Node 2)
    WA->>KP: packet to 10.96.0.1
    KP->>SVC: match KUBE-SVC chain → pick endpoint
    SVC-->>KP: backend = 10.32.0.15
    KP->>DB: DNAT → 10.32.0.15
    Note over KP,DB: forwarded by node rules —<br/>no Service process involved
```

```bash
# Example iptables rules (simplified)
# Traffic to Service IP 10.96.0.1 is redirected to backend Pod 10.32.0.15
iptables -t nat -A KUBE-SVC-xxxxx -d 10.96.0.1 -j KUBE-SEP-yyyyy
iptables -t nat -A KUBE-SEP-yyyyy -j DNAT --to-destination 10.32.0.15
```

---

## 7. Why Does kube-proxy Run on Every Node?

Because Service traffic can originate on **any** node — each node needs the routing rules
**locally**:

```mermaid
flowchart TB
    SVC["⛭ Service · 10.96.0.1"]
    SVC --> N1 & N2 & N3
    subgraph N1["Node 1"]
        K1["⚙ kube-proxy"] --> P1 & P2["pods"]
    end
    subgraph N2["Node 2"]
        K2["⚙ kube-proxy"] --> P3["pod"]
    end
    subgraph N3["Node 3"]
        K3["⚙ kube-proxy"] --> P4 & P5["pods"]
    end
```

When Services change, each node's kube-proxy syncs its own rules — the Service is reachable
regardless of where the request starts.

---

## 8. Installing kube-proxy — Two Paths

**Manual (bare binary):**

```bash
VERSION="v1.36.5"
curl -LO https://dl.k8s.io/${VERSION}/bin/linux/amd64/kube-proxy
chmod +x kube-proxy && sudo mv kube-proxy /usr/local/bin/
sudo useradd --system --no-create-home --shell /usr/sbin/nologin kube-proxy
sudo mkdir -p /var/lib/kube-proxy /etc/kubernetes
# write config.yaml + proxy.conf kubeconfig, then:
sudo systemctl daemon-reload
sudo systemctl enable --now kube-proxy
sudo journalctl -u kube-proxy -f
```

**kubeadm / installers:** kube-proxy ships as a **DaemonSet** — one kube-proxy pod per node,
scheduled automatically (new nodes get it for free).

```mermaid
flowchart TB
    DS["DaemonSet: kube-proxy<br/>'one pod on every node'"]
    DS --> N1["Node 1 · kube-proxy pod"]
    DS --> N2["Node 2 · kube-proxy pod"]
    DS --> N3["Node 3 · kube-proxy pod"]
```

---

## 9. Putting It All Together

| # | Step | What happens |
|---|---|---|
| 1 | Pod network | Pods can reach each other by Pod IP across nodes |
| 2 | Client uses Service | Stable ClusterIP / DNS instead of an ephemeral pod IP |
| 3 | Traffic hits the node | Request to Service IP reaches kube-proxy's rules |
| 4 | kube-proxy routes | iptables/IPVS rewrite → one healthy backend pod |
| 5 | Pod responds | Traffic lands on the backend (e.g. `10.32.0.15`) |
| 6 | Load balancing | Spread across all healthy endpoints — auto-heals on recreate |

```bash
# see it live
kubectl get pods -n kube-system -o wide | grep kube-proxy                    # upstream
oc get pods -n openshift-ovn-kubernetes -o wide | grep ovnkube-node          # OCP
```

---

## 10. OpenShift Note — OVN-Kubernetes Replaces kube-proxy

On **OpenShift 4.x with OVN-Kubernetes** (the default CNI — what lab.ocp.local runs), there is
**no classic kube-proxy**. Service routing is programmed by **OVN**: the `ovnkube-node`
DaemonSet installs OVS/OpenFlow rules that do the same Service IP → endpoint NAT job.
Same mental model, different plumbing.

| Upstream Kubernetes | OpenShift (OVN-Kubernetes) |
|---|---|
| kube-proxy DaemonSet, `kube-system` | `ovnkube-node` DaemonSet, `openshift-ovn-kubernetes` |
| iptables / IPVS rules | OVS / OpenFlow flows via ovnkube |
| `kubectl get pods -n kube-system` | `oc get pods -n openshift-ovn-kubernetes` |

(On a legacy `OpenShiftSDN` cluster, `sdn` pods play the kube-proxy-equivalent role.)

---

## 11. The Takeaway

- The **Pod network** gives every pod reachability.
- A **Service** gives apps a stable IP and DNS name immune to pod recreates — but it's only an
  API object, not a process.
- **kube-proxy**, on every node, is the plumbing that rewrites Service traffic onto real backend
  pods.

> **Service = the address; kube-proxy = the routing.**
> Try it: `oc get svc` → `oc get endpointslices` → inspect the node's NAT rules/OVN flows.
> Watching a packet get DNAT'd from Service IP to pod IP makes this click instantly.
