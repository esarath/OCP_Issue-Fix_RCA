# Issue 06 — `master-2` Transient NotReady / `<unknown>` Metrics After Node Reboot

| Field | Detail |
|---|---|
| **Date** | 2026-07-20 |
| **Severity** | Low |
| **Status** | Resolved (self-healed, no manual action taken) |
| **Affected** | `master-2` only |
| **Root Cause** | Normal but slow OVN-Kubernetes/CNI initialization race after a node reboot — kubelet came up before `ovnkube-node` had written the CNI config, so the node reported `NotReady` (and `oc adm top nodes` showed `<unknown>`) for ~7 minutes until OVN-K finished starting |
| **Resolution Time** | ~7 minutes, unattended |

---

## Symptom

```
oc adm top nodes
NAME                     CPU(cores)   CPU%        MEMORY(bytes)   MEMORY%
master-1.lab.ocp.local   233m         9%          4370Mi          44%
master-3.lab.ocp.local   422m         16%         7855Mi          79%
worker-1.lab.ocp.local   230m         5%          5319Mi          52%
worker-2.lab.ocp.local   192m         4%          4845Mi          48%
master-2.lab.ocp.local   <unknown>    <unknown>   <unknown>       <unknown>
```

`oc get nodes` showed `master-2.lab.ocp.local` as `NotReady`, with condition:

```
Ready=False reason=KubeletNotReady
  message: container runtime network not ready: NetworkReady=false
  reason:NetworkPluginNotReady message:Network plugin returns error:
  No CNI configuration file in /etc/kubernetes/cni/net.d/.
```

Node uptime was only ~13 minutes (boot id `6d8c1b51-4a1f-4514-bf9a-29f8aed1391b`), confirming a recent reboot. `ovnkube-node` and `ovnkube-control-plane` on `master-2` were `PodInitializing`/`ContainerCreating`.

---

## Why This Is a *Different* Issue From Issue 03

This looked identical at first glance to [Issue 03](../03-ovn-kubernetes-crash-loop-after-reboot/) (same `NotReady`/`NetworkPluginNotReady`/`No CNI configuration file` signature), so Issue 03's automated remediation (`fix-ovn-crashloop.sh`, cron `2-59/5 * * * *`) was checked first. It correctly **did not fire**:

```
2026-07-20 00:47:01  No nodes matching the OVN crash-loop signature. Nothing to do.
2026-07-20 00:52:01  No nodes matching the OVN crash-loop signature. Nothing to do.
2026-07-20 00:57:01  No nodes matching the OVN crash-loop signature. Nothing to do.
2026-07-20 01:02:01  No nodes matching the OVN crash-loop signature. Nothing to do.
```

The distinguishing factor: Issue 03 is a genuine crash loop — `ovnkube-controller` panics on startup with a climbing `crictl ps -a` ATTEMPT count, and never recovers on its own. Here, `ovnkube-node`/`ovnkube-control-plane` were simply still finishing normal pod initialization after a reboot (image already present, containers sequentially starting) — no crash, no climbing restart count in the relevant window, just an ordinary "kubelet up before CNI is ready" race that resolves once OVN-K finishes starting.

Confirmed no MachineConfig rollout was in progress (`oc get mcp` showed `UPDATED=True, UPDATING=False` on both pools; all 3 masters were already on the same `rendered-master-...` config, created 2026-06-30 — three weeks prior). The `Uncordon` / `NodeDone` / `ConfigDriftMonitorStarted` events seen around the same time are the Machine Config Operator's normal bookkeeping when any node rejoins `Ready` — not evidence of a fresh config change. The reboot itself was simply the node coming back up (consistent with the [cluster startup checklist](../../checklists/cluster-startup.md) flow), not an MCO-triggered update.

---

## Timeline

| Time (EDT) | Event |
|---|---|
| ~00:45 | `master-2` reboots (boot id `6d8c1b51-4a1f-4514-bf9a-29f8aed1391b`) |
| 00:53:56 | Node condition `Ready` transitions to `False`, reason `KubeletNotReady` / `NetworkPluginNotReady` |
| 00:54:59 | `oc adm top nodes` observed showing `master-2` as `<unknown>` across all columns |
| 00:57:01, 01:02:01 | Cron `fix-ovn-crashloop.sh` scans, finds no matching crash-loop signature (correct — this wasn't that bug) |
| 01:00:40 | `ovnkube-node` finishes initializing; kubelet reports `Ready` |
| 01:13:05 | Confirmed `master-2` `Ready`, `oc adm top nodes` reporting normal CPU/memory again |

---

## Resolution

None required — the condition cleared on its own within ~7 minutes once `ovnkube-node`/`ovnkube-control-plane` finished starting on `master-2` and CNI config was written to `/etc/kubernetes/cni/net.d/`.

---

## Prevention / Guidance for Next Time

1. **Don't assume Issue 03 immediately** just because the message text matches. Check whether the cron log (`/home/centos/ovn-crashloop-fix.log`) shows the crash-loop signature being detected — if it's logging "Nothing to do" during the NotReady window, this is likely just a normal slow-start race like this issue, not the Issue 03 bug.
2. A one-off `<unknown>`/`NotReady` on a single node for a few minutes right after a reboot is expected transient behavior in this cluster — give it up to ~10 minutes before escalating to manual intervention.
3. If it persists beyond ~10 minutes, or `crictl ps -a --name ovnkube-controller` on that node shows a climbing ATTEMPT count, treat it as Issue 03 and let/help the cron script (or the manual steps in that issue) run.
4. `ovnkube-node`/`ovnkube-control-plane` restart counts (78 / 11 respectively at time of writing, over ~19/18 days pod age) are elevated and worth periodic attention — they reflect the cumulative history of past reboot cycles on this cluster, not necessarily active problems, but a sudden jump would be worth investigating.
