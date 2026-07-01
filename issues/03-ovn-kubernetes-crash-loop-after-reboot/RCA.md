# RCA: OVN-Kubernetes Crash Loop on Rebooted Nodes (Web Console Down)

**Applies to:** OCP 4.16.x lab/dev clusters running OVN-Kubernetes in interconnect mode
**Symptom:** Web console unreachable after node reboot; affected nodes stuck `NotReady` with `NetworkPluginNotReady`; zero pending CSRs
**Resolution time:** ~35 minutes

---

## Timeline

| Time (EDT) | Event |
|---|---|
| ~05:00 | `master-1`, `worker-1`, `worker-2` rebooted (uptime ~39-41 min when first checked) |
| 05:40 | Console confirmed unreachable (`curl` → connect timeout / SSL error) |
| 05:40 | Ruled out Issue 01 (kubelet cert expiry): `oc get csr | grep -c Pending` → `0` |
| 05:41 | `oc get nodes` → `master-1` NotReady, `worker-1`/`worker-2` NotReady,SchedulingDisabled; `master-2`/`master-3` Ready |
| 05:42 | Node conditions on all 3 affected nodes: `Ready=False`, reason `KubeletNotReady`, message `No CNI configuration file in /etc/kubernetes/cni/net.d/` |
| 05:44 | SSH to affected nodes: `uptime` showed ~39-41 min (confirmed recent reboot), kubelet/crio both `active` |
| 05:47 | `ovnkube-node` pods on affected nodes showed `ATTEMPT` count climbing every ~20-30s via `crictl ps -a --name ovnkube-controller` — confirmed live crash loop, not a one-off |
| 05:47 | Captured panic trace from kubelet journal (see below) |
| — | Attempted fix 1: force-delete the 3 stuck `ovnkube-node` pods. **Failed** — new pods hit the identical race (`ATTEMPT` reset to low number, then climbed again; on `master-1`/`worker-2` pods got stuck at `PodInitializing` because status patches were rejected by the same unreachable webhook) |
| — | Identified webhook `network-node-identity.openshift.io` (`ValidatingWebhookConfiguration`) targets `https://127.0.0.1:9743/node` and `/pod` — served by `ovnkube-controller` itself |
| 01:48 (post-reset) | Patched both webhook rules to `failurePolicy: Ignore`; force-deleted the 3 stuck pods again |
| +50s | `worker-1` recovered (`8/8 Running`, `Ready`) — crash loop broken. But `master-2`/`master-3`, previously healthy, flipped `Ready → NotReady` with the identical `No CNI configuration file` signature (blast radius spread) |
| — | Reverted webhook `failurePolicy` back to `Fail` immediately; stopped further pod deletions and observed |
| +60s | All 5 nodes `Ready`, all `ovnkube-node` pods `8/8 Running` and stable |
| — | Console still down (`HTTP 000`) — found both workers still `SchedulingDisabled` (cordoned since `2026-06-30T18:23:17Z`, unrelated leftover from prior incident handling) and router pods stuck `Pending` (no schedulable worker) |
| — | `oc adm uncordon worker-1.lab.ocp.local worker-2.lab.ocp.local` |
| +45s | Router pods `1/1 Running`, console returned `HTTP 200` |

---

## Background

OCP 4.16's OVN-Kubernetes runs one `ovnkube-node` DaemonSet pod per node, with a container named `ovnkube-controller` that does double duty:

1. Runs the per-node OVN control logic (gateway reconciliation, chassis registration, annotation management).
2. Serves the `network-node-identity` admission webhook locally on `127.0.0.1:9743`, which validates `nodes/status` and `pods/status` UPDATE requests cluster-wide.

This creates a bootstrapping dependency: on startup, `ovnkube-controller` needs to patch the node's `k8s.ovn.org/l3-gateway-config` annotation, which goes through the API server, which calls back out to the webhook — served by the very same container that hasn't finished starting yet.

---

## Failure Chain

```
Node reboots
        │
        ▼
ovnkube-controller starts, tries to set node annotation
        │
        ▼
API server calls network-node-identity webhook at 127.0.0.1:9743
        │
        ▼
Webhook server not listening yet → dial tcp 127.0.0.1:9743: connect: connection refused
        │
        ▼
kube.go:137 logs the error, gateway.Reconcile() is invoked via Stop()
        │
        ▼
nil pointer dereference in gateway.go:398 → panic → container exits
        │
        ▼
Container restarts → same race repeats (deterministic, not transient)
        │
        ▼
CNI config never written to /etc/kubernetes/cni/net.d/
        │
        ▼
kubelet reports NetworkPluginNotReady → node NotReady
        │
        ├──► DNS pods can't get sandboxes
        ├──► Router pods can't schedule/start
        └──► Web console unreachable
```

### Captured panic (from `journalctl -u kubelet` on `worker-1`, 192.168.29.31)

```
I0701 05:40:10.831075 kube.go:128 Setting annotations map[k8s.ovn.org/l3-gateway-config:...] on node worker-1.lab.ocp.local
E0701 05:40:10.840440 kube.go:137 Error in setting annotation on node worker-1.lab.ocp.local:
  Internal error occurred: failed calling webhook "node.network-node-identity.openshift.io":
  failed to call webhook: Post "https://127.0.0.1:9743/node?timeout=10s":
  dial tcp 127.0.0.1:9743: connect: connection refused
I0701 05:40:10.840461 gateway.go:397 Reconciling gateway with updates
panic: runtime error: invalid memory address or nil pointer dereference
[signal SIGSEGV: segmentation violation code=0x1 addr=0x0 pc=0x1d0cea8]

goroutine 98 [running]:
github.com/ovn-org/ovn-kubernetes/go-controller/pkg/node.(*gateway).Reconcile(0xc001b15600)
	/go/src/github.com/openshift/ovn-kubernetes/go-controller/pkg/node/gateway.go:398 +0x88
github.com/ovn-org/ovn-kubernetes/go-controller/pkg/network-controller-manager.(*nodeNetworkControllerManager).Stop(0xc0001660e0, 0xc0002f110c)
	/go/src/github.com/openshift/ovn-kubernetes/go-controller/pkg/network-controller-manager/node_network_controller_manager.go:177 +0xb5
```

Confirmed live via `crictl ps -a --name ovnkube-controller` — `ATTEMPT` (restart) count climbing every ~20-30s with no stabilization.

---

## Diagnosis Steps

### 1. Rule out kubelet cert expiry (Issue 01) first
```bash
oc get csr | grep -c Pending
# 0 here means it is NOT the cert expiry scenario
```

### 2. Check node conditions for the specific error signature
```bash
oc describe node <node> | sed -n '/Conditions:/,/Addresses:/p'
# Look for: reason=KubeletNotReady
#   message: "No CNI configuration file in /etc/kubernetes/cni/net.d/.
#             Has your network provider started?"
```

### 3. Confirm the node actually rebooted recently
```bash
ssh -i ~/.ssh/ocp4-key core@<node-ip> "uptime"
# Low uptime (minutes, not days) on a subset of nodes = reboot-triggered
```

### 4. Confirm ovnkube-controller is genuinely crash-looping (not just slow)
```bash
ssh -i ~/.ssh/ocp4-key core@<node-ip> "sudo crictl ps -a --name ovnkube-controller"
# Re-run a few times 20-30s apart — ATTEMPT count climbing = confirmed loop

ssh -i ~/.ssh/ocp4-key core@<node-ip> "sudo ss -tlnp | grep 9743"
# No output = webhook server never comes up
```

### 5. Confirm the panic signature in kubelet's journal
```bash
ssh -i ~/.ssh/ocp4-key core@<node-ip> \
  "sudo journalctl -u kubelet --no-pager -n 300 | grep -A20 panic"
# Look for: gateway.go / nodeNetworkControllerManager.Stop / nil pointer dereference
```

---

## Recovery Procedure

### Phase 1 — Confirm scope and identify affected pods
```bash
oc get nodes
oc get pods -n openshift-ovn-kubernetes -o wide | grep -v Running
```

### Phase 2 — Relax the network-node-identity webhook (breaks the deadlock)
```bash
oc get validatingwebhookconfigurations network-node-identity.openshift.io \
  -o jsonpath='{range .webhooks[*]}{.name}{"\t"}{.failurePolicy}{"\n"}{end}'
# Confirm both webhooks (node.* and pod.*) currently Fail

oc patch validatingwebhookconfigurations network-node-identity.openshift.io \
  --type='json' -p='[
    {"op":"replace","path":"/webhooks/0/failurePolicy","value":"Ignore"},
    {"op":"replace","path":"/webhooks/1/failurePolicy","value":"Ignore"}]'
```

### Phase 3 — Force-delete the stuck ovnkube-node pods (one at a time on marginal clusters)
```bash
oc get pods -n openshift-ovn-kubernetes -o wide | grep -v Running
oc delete pod <ovnkube-node-pod> -n openshift-ovn-kubernetes --force --grace-period=0
```
⚠️ Deleting several at once can trigger a cluster-wide OVN interconnect reconciliation ripple that transiently destabilizes otherwise-healthy nodes. Prefer one node at a time when other nodes in the cluster are marginal.

### Phase 4 — Verify recovery and immediately revert the webhook
```bash
oc get pods -n openshift-ovn-kubernetes -o wide
oc get nodes
# Once affected nodes show Ready and ovnkube-node pods are 8/8 Running:

oc patch validatingwebhookconfigurations network-node-identity.openshift.io \
  --type='json' -p='[
    {"op":"replace","path":"/webhooks/0/failurePolicy","value":"Fail"},
    {"op":"replace","path":"/webhooks/1/failurePolicy","value":"Fail"}]'
```

### Phase 5 — Check for cordoned nodes and stuck routers
```bash
oc get nodes
# Any SchedulingDisabled left over? Uncordon:
oc adm uncordon <node>

oc get pods -n openshift-ingress
# Pending routers usually resolve once a schedulable worker exists
```

### Phase 6 — Full verification
```bash
curl -k -s -o /dev/null -w "HTTP %{http_code}\n" \
  https://console-openshift-console.apps.lab.ocp.local
# Expect: HTTP 200

oc get clusteroperator | grep -v "True.*False.*False"
# Expect: no output, or only transient rollouts (ingress/monitoring catching up)

oc get validatingwebhookconfigurations network-node-identity.openshift.io \
  -o jsonpath='{range .webhooks[*]}{.name}{"\t"}{.failurePolicy}{"\n"}{end}'
# Confirm both back to Fail
```

---

## Permanent Automated Remediation

Manual remediation (Phases 2-5 above) is now automated in [`scripts/fix-ovn-crashloop.sh`](scripts/fix-ovn-crashloop.sh) and installed via cron to run every 5 minutes:

```
2-59/5 * * * * /home/centos/fix-ovn-crashloop.sh
```

Key safety properties baked into the script, based on what went wrong during manual remediation on 2026-07-01:

- **Staleness gate**: only acts on a node if its `Ready=False/KubeletNotReady/No CNI configuration file` condition has persisted ≥180s, so a node that's simply still booting normally isn't touched.
- **One node at a time**: pods are deleted sequentially, waiting up to 120s for each node to reach `Ready` before moving to the next. This directly addresses the blast-radius incident where deleting 3 `ovnkube-node` pods simultaneously destabilized 2 previously-healthy masters.
- **Guaranteed webhook revert**: a shell `trap` on `EXIT` reverts `network-node-identity`'s `failurePolicy` back to `Fail` no matter how the script exits (success, error, or interrupted mid-run), so a failed cron run can never leave cluster-wide admission control permanently loosened.
- **Disjoint from Issue 01**: the detection condition (`status=False`, `reason=KubeletNotReady`) is structurally different from the cert-expiry signature (`status=Unknown`, `reason=NodeStatusUnknown`), so this script and `approve-csrs.sh` never fight over the same symptom; both are scheduled via cron (staggered 2 minutes apart) and can run independently.
- **No-op when healthy**: a single fast read pass (`oc get nodes` conditions) with no writes when nothing matches — safe to run every 5 minutes indefinitely.
- **Does not touch cordon state**: deliberately out of scope, since auto-uncordoning could undo an intentional maintenance cordon.

This does not fix the underlying `ovnkube-controller` bug — it contains the blast radius and self-heals within one cron cycle (≤5 min) of a reboot, instead of requiring a human to notice the console is down and manually run the remediation. See [Prevention → Option E](#option-e--track-the-upstream-fix) for the actual root-cause fix path.

---

## Environment Reference (lab.ocp.local)

| Resource | Value |
|---|---|
| HAProxy load balancer | `svc-infra.ocp.local` — 192.168.29.10 |
| Master-1 | `master-1.lab.ocp.local` — 192.168.29.21 |
| Master-2 | `master-2.lab.ocp.local` — 192.168.29.22 |
| Master-3 | `master-3.lab.ocp.local` — 192.168.29.23 |
| Worker-1 | `worker-1.lab.ocp.local` — 192.168.29.31 |
| Worker-2 | `worker-2.lab.ocp.local` — 192.168.29.32 |
| SSH key | `~/.ssh/ocp4-key` (user: `core`) |
| Console URL | `https://console-openshift-console.apps.lab.ocp.local` |
| API URL | `https://api.lab.ocp.local:6443` |
| kubeconfig | `/home/centos/ocp/install/auth/kubeconfig` |

---

## Prevention

### Option A — Stagger node reboots

Reboot one node at a time (with a health check pause in between) rather than rebooting multiple nodes together, so any OVN-K startup race is contained to a single node instead of compounding.

### Option B — Distinguish this from Issue 01 early

```bash
# Run immediately after any post-reboot console outage
oc get csr | grep -c Pending
# 0  → not cert expiry, check ovnkube-controller crash loop (this issue)
# >0 → likely Issue 01, approve CSRs first
```

### Option C — Always revert the webhook failurePolicy change

The `Ignore` patch is a deliberate, temporary loosening of cluster-wide admission control for `nodes/status` and `pods/status` UPDATEs. Never leave it in that state longer than needed to break the crash loop.

### Option D — Verify cordon state after any incident response

Nodes cordoned during earlier troubleshooting (this cluster had both workers cordoned since a prior incident) can silently block recovery of unrelated issues. Always check `oc get nodes` for `SchedulingDisabled` as part of final verification, not just `Ready`/`NotReady`.

### Option E — Track the upstream fix

The panic signature (`nodeNetworkControllerManager.Stop()` called mid-`Start()`, nil-pointer during gateway reconcile) matches a known class of upstream OVN-Kubernetes startup races — see [OCPBUGS-10889](https://redhat.atlassian.net/browse/OCPBUGS-10889) and its fix ([openshift/ovn-kubernetes#1608](https://github.com/openshift/ovn-kubernetes), downstream-merged, originally targeted at OCP 4.14.0). Since this cluster is on 4.16.55 and still hit an apparently-related regression, check future 4.16.z errata for a fix referencing `ovnkube-controller` / `network-node-identity` / `nodeNetworkControllerManager`, and upgrade when available (see [Issue 02](../02-minor-version-upgrade-4.15-to-4.16/RCA.md) for the upgrade runbook). The cron-based auto-remediation (above) should stay in place regardless, as insurance against any other trigger of the same symptom.

---

## Key Diagnostic Commands

```bash
# Is this cert expiry (Issue 01) or this issue?
oc get csr | grep -c Pending

# Is ovnkube-controller actually crash-looping?
ssh -i ~/.ssh/ocp4-key core@<node-ip> "sudo crictl ps -a --name ovnkube-controller"

# Is the identity webhook up on the node?
ssh -i ~/.ssh/ocp4-key core@<node-ip> "sudo ss -tlnp | grep 9743"

# Panic trace
ssh -i ~/.ssh/ocp4-key core@<node-ip> \
  "sudo journalctl -u kubelet --no-pager -n 300 | grep -A20 panic"

# Cluster-wide OVN pod health
oc get pods -n openshift-ovn-kubernetes -o wide

# Cordon state
oc get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.unschedulable}{"\n"}{end}'

# All cluster operator health
oc get clusteroperator
```

---

*RCA created: 2026-07-01*
*Incident: Web console unreachable after reboot of master-1/worker-1/worker-2 — OVN-Kubernetes ovnkube-controller crash loop via self-referential admission webhook race*
