# RCA — Minor Version Upgrade 4.18.50 → 4.19.41: Extensions Image Pull Timeout on master-2

**Cluster**: lab.ocp.local | Proxmox | 3 masters + 2 workers
**Upgrade**: 4.18.50 → 4.19.41
**Detected**: 2026-08-18, upgrade started 15:21 UTC, investigated ~17:22 UTC while stuck at 78%
**Resolved**: 2026-08-18 17:32:41 UTC (self-recovered)

---

## Timeline

| Time (UTC) | Event |
|---|---|
| 15:21:35 | `oc get clusterversion` history shows upgrade to 4.19.41 started, state `Partial` |
| ~17:22 | Investigation begins — upgrade reported "723 of 923 done (78% complete)" but stalled |
| 17:22 | `oc get co` shows `machine-config` and `openshift-apiserver` both Degraded |
| 17:22 | `oc get nodes` shows `master-2` `Ready,SchedulingDisabled`, kubelet still `v1.31.14` |
| 17:22 | `oc get mcp` shows `master` pool: `UPDATED=False UPDATING=True DEGRADED=True`, 2/3 ready, 2/3 updated |
| 17:22 | master-2 MachineConfig annotation `reason` field shows extensions image pull failing after 6 retries with a timeout |
| 17:22–17:29 | Connectivity check launched via `oc debug node/master-2` — pod took >2 min to schedule/run |
| 17:29 | Debug pod result: `curl https://quay.io/v2/` → `http_code=401` in 0.75s (expected/healthy response for unauthenticated registry ping) |
| 17:29 | `journalctl -u crio` on master-2 (persistent, spanning the reboot) shows routine `ImageStatus` checks for `ocp-v4.0-art-dev` layers succeeding, no further timeout errors |
| ~17:29 | `uptime` on master-2 shows node had rebooted ~5 minutes earlier — this is normal MCO behavior (drain → apply MachineConfig → reboot → uncordon) |
| 17:32:41 | `oc get mcp` shows `master` pool `UPDATED=True DEGRADED=False`, 3/3 |
| 17:32:41 | `oc get clusterversion` shows `VERSION=4.19.41`, `PROGRESSING=False`, `STATUS=Cluster version is 4.19.41` |
| 17:33 | `oc get co` — no operators reporting Available=False/Progressing=True/Degraded=True |
| 17:33 | `oc get nodes` — all 5 nodes `Ready`, all on kubelet `v1.32.13` |

Total stuck window observed: at least from ~15:21 (upgrade start, though it likely ran normally for a while before stalling) through 17:32 completion. The specific pull-timeout stall on master-2 cleared within the same investigation window (roughly 10 minutes from detection to resolution), coinciding with the node's scheduled reboot as part of the MCO rollout.

---

## Symptom Detail

### ClusterVersion stuck message
```
NAME      VERSION   AVAILABLE   PROGRESSING   SINCE   STATUS
version   4.18.50   True        True          121m    Working towards 4.19.41: 723 of 923 done (78% complete), waiting up to 40 minutes on openshift-apiserver
```

### Degraded ClusterOperators
```
NAME                  VERSION   AVAILABLE   PROGRESSING   DEGRADED   SINCE   MESSAGE
machine-config        4.18.50   True        True          True       86d     Unable to apply 4.19.41: error during syncRequiredMachineConfigPools:
  [context deadline exceeded, MachineConfigPool master has not progressed to latest configuration:
  controller version mismatch for rendered-master-bdb19826d1da4052059c5d1adcb8dd9e
  expected 9c5e8342612374f653853791f5fadab2db8bed9d has cb086bddfb6c687d4cc49cf86976bc34472ae04b:
  1 (ready 1) out of 3 nodes are updating to latest configuration
  rendered-master-90633db98ffbcec297a1ff6ad562a11a, retrying]
openshift-apiserver   4.19.41   True        False         True       12d     APIServerDeploymentDegraded:
  1 of 3 requested instances are unavailable for apiserver.openshift-apiserver ()
```

> Note: the `SINCE` column values (`86d`, `12d`) reflect when those *condition types* last transitioned in the operator's history, not the duration of this specific incident — a known quirk of `oc get co` output when an operator has flapped through the same condition before.

### Node status
```
NAME                     STATUS                     ROLES                  AGE    VERSION
master-1.lab.ocp.local   Ready                      control-plane,master   141d   v1.32.13
master-2.lab.ocp.local   Ready,SchedulingDisabled   control-plane,master   142d   v1.31.14
master-3.lab.ocp.local   Ready                      control-plane,master   142d   v1.32.13
worker-1.lab.ocp.local   Ready                      worker                 141d   v1.32.13
worker-2.lab.ocp.local   Ready                      worker                 141d   v1.32.13
```

### MachineConfigPool status (stalled)
```
NAME     CONFIG                                             UPDATED   UPDATING   DEGRADED   MACHINECOUNT   READYMACHINECOUNT   UPDATEDMACHINECOUNT   DEGRADEDMACHINECOUNT   AGE
master   rendered-master-bdb19826d1da4052059c5d1adcb8dd9e   False     True       True       3              2                    2                      1                       142d
worker   rendered-worker-8432bd9156eafc0651a0a408597d7c5e   True      False      False      2              2                    2                      0                       142d
```

### master-2 MachineConfig annotations (key excerpt)
```
machineconfiguration.openshift.io/currentConfig: rendered-master-bdb19826d1da4052059c5d1adcb8dd9e
machineconfiguration.openshift.io/desiredConfig: rendered-master-90633db98ffbcec297a1ff6ad562a11a
machineconfiguration.openshift.io/state: Degraded
machineconfiguration.openshift.io/reason: error pulling extensions image
  quay.io/openshift-release-dev/ocp-v4.0-art-dev@sha256:66bdc736371be45c11b3c7d76de727726640446d50beb580180e5c4c2c012e30:
  failed to run command nice (6 tries): [timed out waiting for the condition
```

---

## Investigation

### 1. Ruled out cluster-wide network/proxy misconfiguration
```
oc get proxy cluster -o json   # spec: {} — no proxy configured
oc get image.config.openshift.io cluster -o yaml   # no mirrors configured
oc get imagecontentsourcepolicy,imagedigestmirrorset -A   # No resources found
```
Cluster pulls directly from `quay.io` with no mirror/proxy layer to misconfigure.

### 2. Checked registry reachability from the affected node
```
oc debug node/master-2.lab.ocp.local -- chroot /host curl -sS -o /dev/null \
  -w "http_code=%{http_code} time=%{time_total}s\n" --max-time 10 https://quay.io/v2/
```
Result: `http_code=401 time=0.751135s` — TLS handshake, DNS resolution, and routing to quay.io all worked normally and quickly. `401` is the expected response for an unauthenticated `/v2/` ping, not an error.

Note: the debug pod itself was slow to schedule/start (>2 minutes), which is circumstantial evidence the node was under some transient load/strain around the time of the original pull failures — but by the time it ran, conditions had already normalized.

### 3. Checked node resource pressure
```
oc describe node master-2.lab.ocp.local | grep -A5 Conditions:
```
`MemoryPressure=False`, `DiskPressure=False`, `PIDPressure=False`, `Ready=True`. No indication of resource exhaustion at inspection time.

```
oc debug node/master-2.lab.ocp.local -- chroot /host sh -c "uptime; df -h /var/lib/containers; systemctl is-active crio"
```
`load average: 0.40, 0.51, 0.26`; `/var` 35% used (53G free of 80G); `crio` active. Node was healthy, and had rebooted only ~5 minutes prior (`up 5 min`) — confirming the MCO had cycled the node (drain → config apply → reboot) since the failure was logged.

### 4. Checked persistent journal across the reboot
```
oc debug node/master-2.lab.ocp.local -- chroot /host journalctl -u crio --since "-2h"
```
Only routine `ImageStatus` checks for `ocp-v4.0-art-dev` layers, all succeeding post-reboot. No further timeout entries — the retry after reboot succeeded.

### 5. Confirmed resolution
```
oc get mcp        # master 3/3 UPDATED, DEGRADED=False
oc get clusterversion   # 4.19.41, PROGRESSING=False
oc get co         # all Available=True/Progressing=False/Degraded=False
oc get nodes      # all 5 Ready, v1.32.13
```

---

## Root Cause

`master-2`'s machine-config-daemon needed to pull the `ocp-v4.0-art-dev` extensions image (used to install RHCOS extensions/RPMs as part of the new MachineConfig) while applying the 4.19.41 rendered config. The pull, executed under a `nice`-wrapped command with retry logic, exhausted 6 attempts and timed out, flipping the node to `state: Degraded`. This:

- Stalled the `master` MachineConfigPool at 2/3 updated (only master-1 and master-3 had completed).
- Caused the `machine-config` ClusterOperator to report Degraded (`context deadline exceeded` syncing the pool).
- Caused `openshift-apiserver` to report Degraded/1-of-3-unavailable, because master-2's apiserver instance was down for the node's config-apply/reboot cycle — an expected consequence of the stall extending the single-node-unavailable window past its normal duration, not an independent apiserver problem.

**Contributing factor (unconfirmed but consistent with evidence):** a transient stall pulling from `quay.io`, possibly registry-side rate limiting/latency or brief local resource contention — not a persistent network, DNS, proxy, or pull-secret misconfiguration, all of which were checked and ruled out.

**Why it resolved without intervention:** MCO's own reboot-and-retry cycle for the node re-attempted the config apply (including the image pull) after master-2 rebooted, and the retry succeeded, allowing the pool — and therefore the whole cluster upgrade — to complete normally.

---

## Resolution

No manual fix was applied. The cluster completed the upgrade to 4.19.41 on its own approximately 10 minutes after the stall was first noticed, via MCO's built-in retry behavior.

---

## Recommendations / Follow-ups

1. **If this recurs**: check whether `quay.io/openshift-release-dev/*` pulls are being throttled (rate limits, egress bandwidth) around upgrade windows, especially if multiple nodes stall on the same image.
2. **Consider local release mirroring** (`oc adm release mirror` to an internal registry) if repeated upgrade stalls on image pulls become a pattern — removes the live dependency on quay.io during upgrade windows.
3. **Add this diagnosis sequence to the pre-upgrade runbook** ([issue 02](../02-minor-version-upgrade-4.15-to-4.16/RCA.md)) as an "if the upgrade appears stuck" appendix:
   - `oc get clusterversion` → `oc get co` (filter for unhealthy) → `oc get mcp` → `oc get node <stuck-node> -o jsonpath='...annotations'` (look at the `reason` field) → connectivity/resource check on the node → **wait through one MCO reboot cycle** before considering manual remediation (e.g. forcing a node reboot, checking pull secret, or engaging registry-side troubleshooting).
4. **Don't over-read the `SINCE` column** in `oc get co` output during triage — it reflects condition-type history, not incident duration.
