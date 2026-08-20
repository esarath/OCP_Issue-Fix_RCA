# Issue 09 — Minor Version Upgrade 4.18.50 → 4.19.41: Master Node Stuck on Extensions Image Pull

| Field | Detail |
|---|---|
| **Date** | 2026-08-18 |
| **Severity** | Medium |
| **Status** | Resolved (self-recovered) |
| **Affected** | `machine-config` operator, `openshift-apiserver` operator, `master-2.lab.ocp.local` |
| **Root Cause** | Extensions image pull (`ocp-v4.0-art-dev`) on master-2 timed out 6x during MachineConfig rollout, stalling the master MCP at 2/3 and cascading into apiserver unavailability |
| **Resolution Time** | ~11 minutes (17:21 stuck detected → 17:32 upgrade completed) |
| **Resolution** | None required — node reboot (part of normal MCO update flow) cleared the stall and the retry succeeded |

---

## Symptom

`oc get clusterversion` showed the upgrade stuck at 78% for an extended period:

```
NAME      VERSION   AVAILABLE   PROGRESSING   SINCE   STATUS
version   4.18.50   True        True          121m    Working towards 4.19.41: 723 of 923 done (78% complete), waiting up to 40 minutes on openshift-apiserver
```

`oc get co` showed two operators degraded:

```
NAME                  VERSION   AVAILABLE   PROGRESSING   DEGRADED   MESSAGE
machine-config        4.18.50   True        True          True       Unable to apply 4.19.41: ... MachineConfigPool master has not progressed ...
openshift-apiserver   4.19.41   True        False         True       1 of 3 requested instances are unavailable
```

`master-2.lab.ocp.local` was `Ready,SchedulingDisabled`, still on kubelet `v1.31.14` while master-1/3 were already on `v1.32.13`. Its MachineConfig annotation showed:

```
machineconfiguration.openshift.io/state: Degraded
machineconfiguration.openshift.io/reason: error pulling extensions image
  quay.io/openshift-release-dev/ocp-v4.0-art-dev@sha256:...:
  failed to run command nice (6 tries): [timed out waiting for the condition
```

---

## Diagnosis Steps Taken

1. **Confirmed it was a real stall, not just slow progress** — `oc get mcp` showed `master` pool `UPDATING=True`, `DEGRADED=True`, 2/3 machines updated, unchanged across checks.
2. **Ruled out hard network/DNS failure** — `oc debug node/master-2 -- curl -sS https://quay.io/v2/` returned `401` (expected unauthenticated response) in <1s once the debug pod scheduled. Registry reachability itself was fine.
3. **Noted the debug pod itself took >2 minutes to reach `ContainerCreating`→running** — consistent with a node under transient strain rather than a clean network outage.
4. **Checked node conditions/resources** — no DiskPressure/MemoryPressure/PIDPressure; `/var` at 35% used; load average low. Nothing pointed to resource exhaustion at the time of inspection.
5. **Found the node had just rebooted** (`uptime` showed ~5 minutes) — this is expected MCO behavior when applying a new rendered MachineConfig, and it reset the stuck pull attempt.
6. **Re-checked status shortly after** — `oc get mcp` showed `master` at 3/3 `UPDATED=True`, `DEGRADED=False`; `oc get clusterversion` showed `4.19.41`, `Progressing=False`. All clusteroperators returned to `Available=True/Progressing=False/Degraded=False`. All 5 nodes `Ready` on `v1.32.13`.

No manual remediation was applied — the routine reboot-and-retry cycle built into MCO resolved the transient pull timeout on its own.

---

## Root Cause (Summary)

During the 4.18.50 → 4.19.41 upgrade, `master-2` needed to pull the `ocp-v4.0-art-dev` extensions image as part of applying its new rendered MachineConfig. The pull (wrapped in a `nice`-priority command by the machine-config-daemon) timed out repeatedly (6 retries exhausted), marking the node `Degraded` and stalling the `master` MachineConfigPool at 2/3. Because a control-plane node was mid-drain/reboot for the update, `openshift-apiserver` also reported 1 of 3 instances unavailable — an expected side effect of a single-master-at-a-time rollout, not a separate fault.

The exact trigger for the pull timeout wasn't conclusively identified — connectivity to quay.io was healthy when checked — but it's consistent with a transient registry stall or brief resource contention on the node during the update. The subsequent node reboot (normal MCO behavior) cleared the condition and the retry succeeded.

Full analysis → [RCA.md](RCA.md)

---

## Files

| File | Description |
|---|---|
| [RCA.md](RCA.md) | Full timeline, commands used, and analysis |

---

## Prevention / Watch Items

- No fix needed this time, but if this recurs on future upgrades:
  - Check registry-side throttling/rate limits for `quay.io/openshift-release-dev/*` if the pattern repeats.
  - Consider mirroring release images locally (`oc adm release mirror`) to remove the dependency on live quay.io pulls during upgrades if repeated stalls occur.
  - During any future stuck upgrade, use the same diagnosis sequence: `oc get clusterversion` → `oc get co` (filter unhealthy) → `oc get mcp` → node MachineConfig annotations (`reason` field) → connectivity/resource check → wait through one MCO reboot cycle before considering manual intervention.
