# What happens when you deploy — the full flow, step by step

![Colour key for the deployment-flow diagrams](diagrams/00-legend.png)

---

## The restaurant analogy

Think of it like placing an order at a restaurant: you tell the **front desk** (API server), the order gets **written down** (etcd), the **kitchen manager** (controller) breaks it into tasks, a **host** assigns a table (scheduler), and a **waiter** actually serves it (kubelet).

![Restaurant analogy: front desk is the API server, order book is etcd, kitchen manager is the controller, host is the scheduler, waiter is the kubelet](diagrams/01-restaurant-analogy.png)

![Full deploy flow: everything talks only to the API server, which stores state in etcd; controllers, scheduler and kubelet watch it](diagrams/02-full-flow.png)

---

## Step 1 — You submit the request

`oc` / `kubectl` sends the Deployment YAML to the API server (**kube-apiserver**). This is the only component you ever talk to — everything else reacts to it.

```bash
oc apply -f deployment.yaml     # or oc create deployment / helm install
```

![Step 1: oc apply sends the Deployment YAML to the API server](diagrams/03-step1-submit.png)

---

## Step 2 — API server validates and stores

The API server:

- **Authenticates** you (who are you?) and **authorizes** you (can you create deployments? via RBAC)
- **Validates** the YAML against the schema (wrong field? rejected here)
- Runs **admission webhooks** (OpenShift's SCC / SecurityContextConstraints inject things like the user ID the container must run as)
- **Writes the object to etcd** — the cluster's database. Only now does the Deployment "exist"

![Step 2: API server authenticates, authorizes via RBAC, validates schema, runs admission such as SCC, then writes to etcd](diagrams/04-step2-apiserver.png)

> **Important:** Nothing is running yet. It's just a desired state written in etcd — "I want 3 replicas of this image."

---

## Step 3 — Deployment controller reacts

The **controller manager** has dozens of controllers watching the API server for changes. The **Deployment controller** sees the new Deployment and creates a **ReplicaSet** object with `replicas: 3` and your pod template.

---

## Step 4 — ReplicaSet controller creates Pods

The **ReplicaSet controller** sees "3 desired, 0 exist" and creates 3 **Pod** objects in etcd. Pods get names like `myapp-7d9f4b8c6-x2vkl`. At this point each pod is `Pending` with `spec.nodeName` empty.

![Steps 3 and 4: Deployment controller creates a ReplicaSet; ReplicaSet controller creates three Pending pods](diagrams/05-step3-4-controllers.png)

---

## Step 5 — Scheduler picks a node

The **scheduler** watches for pods with no node assigned. For each pod it:

- **Filters** nodes: enough CPU/memory? right labels/taints? `NotReady` nodes are excluded — this is exactly why pods were stuck on the lab cluster: only 2 Ready nodes
- **Scores** the remaining nodes (spread across zones/nodes, locality, etc.)
- Writes `spec.nodeName: worker-2` — this is the **binding**

![Step 5: scheduler filters nodes, scores the rest, then binds the pod to the winner](diagrams/06-step5-scheduler.png)

---

## Step 6 — Kubelet takes over on the node

The **kubelet** on the chosen node sees a pod assigned to it:

- **Pulls the image** via **CRI-O** (the container runtime): `crio` → registry → image layers stored locally
- Asks CRI-O to create the **pod sandbox + containers**
- **Mounts volumes**, injects ConfigMaps / Secrets / Services env vars
- **Runs the entrypoint** → container starts

![Step 6: kubelet on the chosen node pulls the image via CRI-O, creates sandbox and containers, mounts volumes, starts entrypoint](diagrams/07-step6-kubelet.png)

---

## Step 7 — Health checks & networking

- **Startup / readiness / liveness probes** run — readiness must pass before the pod gets traffic
- **CNI plugin** (OVN-Kubernetes on OCP) gave the pod its IP at sandbox creation
- Once Ready, the **Endpoints / EndpointSlice controller** adds the pod's IP to the Service's endpoint list → traffic flows
- Kubelet **reports status** back to the API server → `kubectl get pods` shows `Running 1/1`

![Step 7: CNI gives the pod an IP, probes run, readiness adds the pod to EndpointSlice, Service sends traffic, kubelet reports Running](diagrams/08-step7-health-network.png)

---

## Step 8 — The loop never stops

Every controller runs a **reconcile loop**: "desired vs. actual." Pod crashes? ReplicaSet notices 2/3 and creates a replacement — it doesn't restart it, it makes a **new pod** (possibly on another node).

![Step 8: reconcile loop observes actual state, compares with desired, and creates a new pod when one crashes](diagrams/09-step8-reconcile.png)

> **Core idea of Kubernetes:** Declarative desired state + continuous reconciliation.

---

## On `oc rollout` / update

Same flow, one twist: the Deployment controller creates a **new ReplicaSet** (`myapp-8f4e...`) and gradually **scales it up** while **scaling the old one down** — `maxSurge` / `maxUnavailable` control the pace. The old ReplicaSet is kept (scaled to 0) for `oc rollout undo`.

![oc rollout: Deployment controller scales new ReplicaSet up and old ReplicaSet down, keeping the old one at zero for undo](diagrams/10-rollout.png)

---

## The mental model

```text
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

![Mental model: You, API server, etcd; controllers create pods; scheduler binds; kubelet with CRI-O and CNI runs; probes and endpoints send traffic](diagrams/11-mental-model.png)

> **One-line summary:** You declare what you want in etcd; controllers, the scheduler, and kubelets independently conspire to make reality match it — and keep matching it forever.

---

## Where it commonly breaks

Both of these have been seen on the lab cluster:

- Stuck `Pending` → **scheduler found no node** (NotReady nodes, no capacity, taints)
- `Pending` forever **with node assigned** → **kubelet can't pull the image or can't reach the API** (expired certs — see Issue 07)

![Where it breaks: Pending with no node means scheduler failure; Pending with a node assigned means kubelet cannot pull image or reach the API](diagrams/12-where-it-breaks.png)

