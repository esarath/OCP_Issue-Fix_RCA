# RCA — Master RAM Constraint Blocking 4.19 → 4.20 Upgrade

## Root Cause

The 3 master VMs on `lab.ocp.local` were provisioned with ~11GB RAM each.
Red Hat's stated minimum for an OCP control-plane node is 16GB. This is not
a misconfiguration or a leak — it's genuinely undersized allocation from
initial provisioning, confirmed by process-level accounting on each master:

| Component (master-3, the tightest node) | Memory |
|---|---|
| `kube-apiserver` | ~2.6GB |
| `etcd` | significant, not separately broken out here |
| OVN-Kubernetes control-plane pods | significant |
| `openshift-apiserver` | present |
| OLM singletons (`catalog-operator`, `packageserver`) | present |

None of this is reclaimable in-cluster — it's the normal, expected resource
footprint of a healthy OCP control plane at this scale. The only two levers
available were (a) remove non-essential in-cluster load, or (b) give the
masters more RAM at the hypervisor level.

## Contributing factor investigated and ruled out first

OpenShift Virtualization (CNV) was installed and running its full
control-plane stack (~34 pods, ~2.7GB) while managing zero actual VMs, for
85+ days — leftover from an abandoned VM-migration pilot (issue 05).
Uninstalling it (issue 12) helped `worker-1`, `master-1`, and `master-2`
meaningfully, but **`master-3` stayed flat at 85-88% memory** because it had
never hosted much CNV load in the first place — its pressure was always
coming from standard control-plane pods, not something removable.

This matters for future readiness checks: don't assume the CNV-style "find
something reclaimable" pattern will work twice. Once genuine platform
components account for the pressure, the only remaining lever is host-level
RAM.

## Decision

Considered three options at the hypervisor level:
1. **Full RH-minimum compliance** (16GB × 3 masters, +14.3GB total) — ruled
   out: would have left under 1GB true free RAM on the 62.4GB physical host
   after trimming what could be trimmed elsewhere (the oversized `svc-infra`
   VM). Too risky given a stopped 20.48GB `Docker` VM is a standing
   contingent liability if it's ever powered back on.
2. **No change, accept the risk as-is** — ruled out: masters were already
   running at ~94% of their old ~11GB allocation under *normal* load, before
   even accounting for the extra transient headroom a y-stream upgrade's
   overlapping-component rollout needs.
3. **Partial bump to 14GB/master (+8.3GB total)** — **chosen**. Fits inside
   existing free host RAM with ~3.5GB spare left over. Still under Red Hat's
   stated minimum (an accepted, documented risk, not a cleared one) but
   relieves the actual measured pressure that motivated pausing the upgrade
   in the first place.

## Verification

- All 3 masters report ~13.65GiB allocatable post-change (up from the
  original ~11GB), confirmed via `oc get nodes -o jsonpath='...status.allocatable.memory'`.
- Re-checked one day later (2026-08-27, this issue's Part 4): masters
  holding steady at 53-85% memory, no regression, no new pressure.
- etcd stayed at quorum throughout the rolling change (never more than 1 of
  3 members down simultaneously) — zero application/control-plane downtime
  during the remediation itself.

## Prevention / Process Improvement

- **Log operational changes as issues at the time they happen, not
  retroactively.** This RAM fix, the disk prune, and the etcd backup all
  happened 2026-08-26 but weren't captured in this repo until this issue was
  written the next day. The gap risked losing the Proxmox-side gotcha
  (master-3's shutdown command silently failing) if it hadn't been carried
  forward in a memory/notes system outside this repo.
- **A reusable minor-upgrade checklist didn't exist before this issue** —
  only the z-stream variant did (from issue 11's readiness review). Y-stream
  upgrades have materially different risk (API deprecations, no rollback,
  every node reboots, longer windows) and deserved their own document. See
  [checklists/minor-version-upgrade-procedure.md](../../checklists/minor-version-upgrade-procedure.md).
- **Same-day re-checks matter.** RAM and disk figures from 2026-08-26 were
  re-validated 2026-08-27 rather than trusted as still current — this should
  be standard practice any time more than same-day has passed between a
  readiness check and the actual upgrade window.
