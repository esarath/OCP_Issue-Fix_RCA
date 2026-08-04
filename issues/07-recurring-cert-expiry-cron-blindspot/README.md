# Issue 07 — Recurring Kubelet Cert Expiry After Extended Shutdown; Cron Automation Blind Spot Found & Fixed

| Field | Detail |
|---|---|
| **Date** | 2026-08-04 |
| **Severity** | Medium |
| **Status** | Resolved |
| **Affected** | `master-1`, `worker-1`, `worker-2` (NotReady); briefly all 5 nodes during recovery |
| **Root Cause** | Same underlying cause as [Issue 01](../01-web-console-unreachable/) — kubelet certs expired during ~2 weeks of cluster downtime (last activity 2026-07-20, cluster restarted 2026-08-04). **New finding**: the cron automation that was supposed to auto-remediate this (`approve-csrs.sh`, `*/5 * * * *`) had a silent-failure blind spot that made it look healthy throughout the entire outage. |
| **Resolution Time** | ~15 minutes (manual CSR approval + monitoring to full Ready), plus a script hardening fix |

---

## Symptom

`oc get nodes` showed 3 of 5 nodes `NotReady`:

```
master-1.lab.ocp.local   NotReady   control-plane,master
worker-1.lab.ocp.local   NotReady   worker
worker-2.lab.ocp.local   NotReady   worker
```

`oc get csr` showed 8 `Pending` kubelet-client CSRs (`system:serviceaccount:openshift-machine-config-operator:node-bootstrapper`), ages 42s–19m — the standard signature from [Issue 01](../01-web-console-unreachable/).

## The New Finding — Cron Was Silently Blind, Not Broken

`approve-csrs.sh` has run via cron (`*/5 * * * *`) since 2026-06-30 (Issue 01's prevention step). It **is** persistent across bastion reboots (`crond` is systemd-enabled/active) and does not depend on the OCP cluster being up.

`csr-approval.log` showed it firing every 5 minutes and logging `"No pending CSRs found"` / `"All nodes Ready"` continuously — including through the *entire* ~2-week window the cluster was completely powered off. That's wrong: the API was unreachable that whole time, so every `oc` call in the script should have failed.

Cause: every `oc` call in the script is suffixed with `2>/dev/null`. When `oc get csr` fails outright (API unreachable), its output is empty — identical to the output when there are genuinely zero pending CSRs. `grep -c Pending` on empty input returns `0` either way, so the script cannot distinguish "cluster is down, I can't check" from "cluster is healthy." The log looked green the entire time the cluster was dark.

This meant that on today's restart, nothing was actually broken about the recovery logic — it plausibly did fire and start converging things on its own on schedule — but the log gave no early warning that the automation had been flying blind for two weeks, which is the more dangerous failure mode (silent false-positive health signal vs. loud failure).

## Fix Applied

Added a preflight check to `approve-csrs.sh`, before any phase runs:

```bash
if ! oc whoami >/dev/null 2>&1; then
    log "ERROR: Cannot reach cluster API (oc whoami failed) — cluster may be down or still booting. Skipping this cycle, will retry in 5 min."
    exit 1
fi
```

Now an unreachable API produces a distinct, loud `ERROR` line every 5 minutes instead of a false `"healthy"` line. Verified with `bash approve-csrs.sh --dry-run` against the live (healthy) cluster — preflight passes through cleanly and all 6 phases still run as before.

Updated copy committed here: [`scripts/approve-csrs.sh`](scripts/approve-csrs.sh) (also updated in place at `/home/centos/approve-csrs.sh` and the repo's top-level `scripts/approve-csrs.sh`, which the README documents as the canonical latest version).

## Secondary Finding (Red Herring, Documented for Future Triage)

While nodes were recovering, `kube-apiserver` clusteroperator showed `Progressing=True`: `"2 nodes are at revision 27; 1 node is at revision 30"`. This looked like a stuck rollout at first glance (the condition's `lastTransitionTime` read 2026-03-29, which is misleading — that's just when the condition type was last created, not when it got stuck).

It was not stuck. The operator log (`kube-apiserver-operator` deployment) showed it was a live, actively-converging static-pod rollout to revision 30, triggered by the same kubelet bounce cycle as the cert recovery. It finished on its own within ~2 minutes:

```
11:26:33 Event: NodeCurrentRevisionChanged — Updated node "master-1.lab.ocp.local" from revision 27 to 30
11:26:33 Event: OperatorStatusChanged — Progressing changed from True to False ("NodeInstallerProgressing: 3 nodes are at revision 30")
```

**Guidance for next time:** if `kube-apiserver` (or any static-pod operator) shows `Progressing=True` with a "N nodes at revision X, M at revision Y" message during/right after a node recovery event, check `oc get pods -n openshift-kube-apiserver -l apiserver=true -o custom-columns=NAME:.metadata.name,STATUS:.status.phase,REVISION:.metadata.labels.revision` a couple of times a minute apart before assuming it's stuck — it's very likely just catching up node-by-node as kubelets restart, same as this incident. Only escalate if the revision numbers stop changing across multiple checks.

---

## Timeline (EDT, 2026-08-04)

| Time | Event |
|---|---|
| ~06:4x | Cluster VMs started after ~2-week shutdown (since 2026-07-20) |
| 06:45–07:15 | Cron `approve-csrs.sh` runs every 5 min, logs false "healthy" (API actually still settling/unreachable at points) |
| ~07:1x | Manual check: 3/5 nodes `NotReady`, 8 CSRs `Pending` |
| ~07:1x | Manually approved all pending CSRs (`oc get csr -o name \| xargs oc adm certificate approve`) |
| 07:1x–07:2x | Nodes flapped Ready/NotReady while OVN/kubelet finished restarting (same benign pattern as [Issue 06](../06-master-2-transient-notready-after-reboot/)); monitored to full convergence |
| 07:21 | All 5 nodes `Ready`, 0 pending CSRs |
| 07:2x | Noticed `kube-apiserver` clusteroperator `Progressing=True`; investigated, confirmed benign live rollout |
| 11:26:33 UTC | `kube-apiserver` rollout completes — all 3 masters at revision 30, `Progressing=False` |
| 07:2x | Hardened `approve-csrs.sh` with API-reachability preflight check; verified via dry-run |

---

## Files

| File | Description |
|---|---|
| [scripts/approve-csrs.sh](scripts/approve-csrs.sh) | Updated recovery script with API-reachability preflight check |

---

## Prevention

1. Same as [Issue 01](../01-web-console-unreachable/): the cron automation already covers this — no new cron entry needed, and it survives bastion reboots.
2. **New:** if reviewing `csr-approval.log` to confirm the automation is healthy, be aware that prior to this fix, a string of `"No pending CSRs found"` lines could mean either "genuinely healthy" or "couldn't reach the API at all." Post-fix, a real outage now shows explicit `ERROR: Cannot reach cluster API` lines instead — trust those over an unbroken string of "healthy" lines from before this date.
3. Don't chase `kube-apiserver` (or other static-pod operator) `Progressing=True` as a new incident during/right after a node recovery without first checking whether the per-node revision numbers are actually moving — see the red-herring section above.
