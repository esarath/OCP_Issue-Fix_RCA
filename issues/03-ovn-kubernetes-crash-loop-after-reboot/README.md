# Issue 03 — OVN-Kubernetes Crash Loop on Rebooted Nodes (Web Console Down)

| Field | Detail |
|---|---|
| **Date** | 2026-07-01 |
| **Severity** | High |
| **Status** | Resolved |
| **Affected** | Web console, ingress routers, DNS, master-1, worker-1, worker-2 |
| **Root Cause** | `ovnkube-controller` panics on startup in a self-referential webhook race, crash-looping indefinitely and blocking CNI configuration |
| **Resolution Time** | ~35 minutes |

---

## Symptom

`https://console-openshift-console.apps.lab.ocp.local` was unreachable after `master-1`, `worker-1`, and `worker-2` were rebooted.

```
curl -k https://console-openshift-console.apps.lab.ocp.local
# HTTP 000 / SSL connect error
```

Unlike [Issue 01](../01-web-console-unreachable/), there were **zero pending CSRs** — this was not the kubelet cert expiry case. All 3 affected nodes showed:

```
oc get nodes
# NotReady / NotReady,SchedulingDisabled

# node condition:
Ready=False reason=KubeletNotReady
  message: container runtime network not ready: NetworkReady=false
  reason:NetworkPluginNotReady message:Network plugin returns error:
  No CNI configuration file in /etc/kubernetes/cni/net.d/.
```

---

## Quick Fix

```bash
# 1. Confirm it's the OVN webhook race, not cert expiry (0 pending CSRs)
oc get csr | grep -c Pending

# 2. Confirm ovnkube-controller is actually crash-looping (not just slow)
ssh -i ~/.ssh/ocp4-key core@<node-ip> "sudo crictl ps -a --name ovnkube-controller"
# ATTEMPT count climbing every ~20-30s = confirmed crash loop

# 3. Temporarily relax the network-node-identity webhook so kubelet's
#    status patches succeed while ovnkube-controller is still starting
oc patch validatingwebhookconfigurations network-node-identity.openshift.io \
  --type='json' -p='[
    {"op":"replace","path":"/webhooks/0/failurePolicy","value":"Ignore"},
    {"op":"replace","path":"/webhooks/1/failurePolicy","value":"Ignore"}]'

# 4. Force-delete the stuck ovnkube-node pods on the affected nodes only
oc delete pod ovnkube-node-<hash1> ovnkube-node-<hash2> ovnkube-node-<hash3> \
  -n openshift-ovn-kubernetes --force --grace-period=0

# 5. Once nodes report Ready, revert the webhook immediately
oc patch validatingwebhookconfigurations network-node-identity.openshift.io \
  --type='json' -p='[
    {"op":"replace","path":"/webhooks/0/failurePolicy","value":"Fail"},
    {"op":"replace","path":"/webhooks/1/failurePolicy","value":"Fail"}]'

# 6. Uncordon any workers left SchedulingDisabled and verify console
oc adm uncordon <worker-node>
curl -k -s -o /dev/null -w "%{http_code}" https://console-openshift-console.apps.lab.ocp.local
# Expected: 200
```

⚠️ **Do not delete all affected `ovnkube-node` pods in one shot without the webhook patch first** — see [Blast Radius Warning](#blast-radius-warning) below.

---

## Root Cause (Summary)

On OCP 4.16, the `network-node-identity` admission webhook (which validates `nodes/status` and `pods/status` UPDATEs) is served **by the `ovnkube-controller` container itself**, on `127.0.0.1:9743`. On startup, `ovnkube-controller` tries to set the node's gateway annotation, which requires calling that same webhook — but the webhook server isn't listening yet. The failed call is mishandled: it triggers a `Stop()` path that hits a nil-pointer dereference in `gateway.Reconcile()`, killing the container. The container restarts straight back into the same race, forever.

Because `ovnkube-controller` never stays up, CNI configuration is never written, so kubelet reports `NetworkPluginNotReady` / `NodeNotReady` indefinitely on the affected node.

Full analysis → [RCA.md](RCA.md)

---

## Blast Radius Warning

Force-deleting all 3 stuck `ovnkube-node` pods **simultaneously**, without first patching the webhook, does not help — it re-enters the identical deterministic race on all 3 nodes.

Patching the webhook to `failurePolicy: Ignore` and **then** deleting all 3 pods at once broke the individual crash loops, but the simultaneous OVN interconnect reconciliation across 3 nodes at once briefly destabilized the 2 previously-healthy masters (`master-2`, `master-3` flipped `Ready → NotReady` for ~2 minutes) before self-recovering. Reverting the webhook to `Fail` and waiting ~60s without further pod deletions let the whole cluster settle.

**Prefer deleting the stuck pods one at a time** (not all 3 at once) if attempting this fix on a cluster where other nodes are marginal, to avoid this ripple effect.

---

## Files

| File | Description |
|---|---|
| [RCA.md](RCA.md) | Full root cause analysis, panic trace, diagnosis steps, and recovery timeline |

---

## Prevention

- Reboot masters/workers **one at a time**, not in bulk, so any OVN-K startup race only affects a single node and its neighbors can absorb the transient load.
- After any node reboot, check for this signature before assuming cert expiry ([Issue 01](../01-web-console-unreachable/)):
  ```bash
  oc get csr | grep -c Pending   # 0 here rules out Issue 01
  ssh core@<node> "sudo crictl ps -a --name ovnkube-controller"  # climbing ATTEMPT count = this issue
  ```
- Always revert the `network-node-identity` webhook `failurePolicy` back to `Fail` as soon as affected nodes report `Ready` — it is a temporary loosening of admission control cluster-wide.
- Check for cordoned nodes left over from the incident (`oc get nodes` → `SchedulingDisabled`) — uncordon before declaring recovery complete, since ingress routers can't schedule otherwise.
