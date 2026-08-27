# Checklist — Minor (Y-Stream) Version Upgrade Procedure (e.g. 4.19 → 4.20)

**Use this when**: applying a minor/y-stream OpenShift update via the CVO —
a bigger step than a z-stream (`checklists/z-stream-patch-procedure.md`):
API deprecations are possible, Kubernetes minor version changes, and every
component (control plane, nodes, OLM operators) needs its own compatibility
check against the target, not just the errata. Drafted against the live
4.19 → 4.20 readiness effort on `lab.ocp.local` (readiness review: [issue 11](../issues/11-4.19.43-patch-readiness-review/README.md);
RAM blocker + remediation: [issue 08](../issues/08-upgrade-4.19.41-to-4.19.42-and-channel-drift/README.md),
[issue 12](../issues/12-uninstall-idle-cnv-reclaim-resources/README.md), [issue 13](../issues/13-420-upgrade-readiness-ram-remediation-and-prechecks/README.md)) —
reusable for future y-streams on this cluster (4.20→4.21, etc.).

**Related history on this cluster**: [issue 02](../issues/02-minor-version-upgrade-4.15-to-4.16/README.md)
(prior minor upgrade, 4.15→4.16 — hit PDB-blocked drains twice and an image
pull rate limit, all fixed live) · [issue 04](../issues/04-oc-client-server-version-skew/README.md)
(bastion `oc` client silently drifted a version behind after that upgrade) ·
[issues 08, 09](../issues/08-upgrade-4.19.41-to-4.19.42-and-channel-drift/README.md)
(two separate self-recovered worker image-pull stalls during MCO rollout,
different root cause each time — treat as a recurring category, not a fluke).

---

## 1. What's different about a y-stream vs. a z-stream

| Component | Z-stream | Y-stream (this checklist) |
|---|---|---|
| Kubernetes minor version | Same | **Bumps** — new kubelet/API server minor version |
| API removals | Never | **Possible** — check the target release's API deprecation/removal notes before scheduling |
| CVO Runlevel count / duration | Shorter | Longer — more components genuinely change, not just patched |
| OLM/vendor operator compatibility | Usually safe | **Must be explicitly confirmed per operator** against the new y-stream, not assumed from "worked on prior z-stream" |
| Rollback | None (etcd restore only) | **None** — y-stream upgrades are one-directional; a downgrade is not supported at all, even by restore-and-reprovision in most cases. Treat the go/no-go decision as final. |
| RHCOS / node OS | Sometimes bumped | Always bumped — every node reboots |

**Net effect**: budget more time, more validation, and treat "it worked last
z-stream" as zero evidence for this upgrade.

---

## 2. Pre-flight validation checklist

Run [`scripts/pre-upgrade-check.sh`](../issues/13-420-upgrade-readiness-ram-remediation-and-prechecks/scripts/pre-upgrade-check.sh)
(target version as arg) for the automatable items, then confirm the rest manually:

- [ ] `oc get co` / `oc get nodes` / `oc get mcp` — cluster fully healthy, nothing already degraded, CV not already `Progressing=True`
- [ ] `oc get csr | grep Pending` — zero pending CSRs
- [ ] `oc adm upgrade` — confirm the target version is actually recommended on the intended channel (don't assume `candidate-*` == safe; use `stable-*` or the documented EUS path unless there's a specific reason not to)
- [ ] `oc get clusterversion version -o jsonpath='{.spec.channel}'` — confirm it's what you expect it to be *right before* switching — this cluster has a documented channel-drift incident (issue 08)
- [ ] `oc get clusterversion version -o json` → `.status.conditionalUpdates` — empty, or every listed risk explicitly reviewed and accepted
- [ ] Fresh etcd backup taken **and copied off-node** (§4) — not older than the start of the maintenance window
- [ ] `oc adm top nodes` + `oc get nodes -o jsonpath='...status.allocatable.memory'` — record current headroom as the pre-upgrade baseline; a y-stream's overlapping-component rollout needs more transient headroom than a z-stream, so don't skip this even if RAM was already validated days earlier — re-check same-day
- [ ] Node disk usage under ~50% on every node (`df -h /var`) — release image pulls add real pressure; prune (`crictl rmi --prune` via `oc debug node/<n> -- chroot /host`) if any node is tight
- [ ] `oc get pdb -A | awk '$5==0'` — zero PDBs with `allowedDisruptions=0` (these will hard-block a node drain, not just delay it); if any exist, plan to scale up the workload or temporarily delete/relax the PDB before that node's drain window
- [ ] `oc get csv -A` — enumerate every installed OLM operator; for each, confirm the vendor's own release notes state explicit support for the target y-stream (don't infer from "same major, prior minor worked") — as of this writing, this cluster's only non-platform operator is `openshift-lightspeed`
- [ ] `oc get vm -A` / `oc get vmi -A` — if this ever returns results again (CNV reinstalled), treat VM live-migration planning as mandatory per §3 of the z-stream checklist; as of the 4.19→4.20 effort, CNV is uninstalled (issue 12) and this step is a no-op
- [ ] Single-replica / no-PDB app inventory — flag and notify owners (this lab cluster currently has no user application workloads beyond `nfs-provisioner`; re-check if that changes)
- [ ] Release notes / API deprecation notice for the specific target version reviewed — look for any resource your workloads actually use in the "removed APIs" list for that release
- [ ] `oc whoami` — using a named, attributable admin account for the channel switch and `oc adm upgrade`, not the shared `kubeadmin` bootstrap credential (issue 08's channel-drift incident traced to an unattributable `kube:admin` session; `babus` was onboarded as a named admin in issue 10 for exactly this)
- [ ] Bastion `oc` client version noted — plan to refresh it post-upgrade (issue 04: it silently drifted a version behind after the last minor upgrade and nothing alerted on it)
- [ ] Change ticket / maintenance window approved with this checklist attached

---

## 3. Expected downtime / disruption profile

**No full cluster outage in a normal y-stream upgrade**, same guarantee as a
z-stream, but every phase runs longer and every node reboots (not
conditional on RHCOS bump, unlike a z-stream):

| Phase | Typical duration | User-visible impact |
|---|---|---|
| Control plane rollout (3 masters, sequential) | ~30–60 min | Each master briefly unavailable during its own restart; API stays reachable throughout via the other two — never take masters out of order or in parallel |
| Worker rollout (2 workers, `maxUnavailable: 1` default) | ~15–30 min per worker (reboot is mandatory for a y-stream) | Workloads rescheduled/restarted on the draining worker; zero downtime for 2+-replica apps with a satisfiable PDB, real (if brief) downtime for single-replica/no-PDB apps |
| **Total wall clock (this cluster's own z-stream history, scaled up)** | Issue 02 (4.15→4.16, prior y-stream on this cluster): **~4h 24m**, driven by 3 separate manual interventions (2 PDB blocks + 1 registry rate-limit), not raw CVO time | Budget similarly until this cluster demonstrates a clean, no-intervention y-stream run |

**Recommended maintenance window: 3–5 hours** — a y-stream on this cluster
has never completed in under 4 hours once, and the known image-pull-stall
pattern (issues 08, 09) can add 10–40 min unpredictably.

---

## 4. Backup & restoration plan

Same procedure and decision ladder as [z-stream-patch-procedure.md §7](z-stream-patch-procedure.md#7-backup--restoration-plan) —
not repeated here to avoid drift between two copies. Key reminders specific
to a y-stream:

- **There is no downgrade path at all for a y-stream**, more absolute than
  the z-stream's "no supported downgrade, only etcd restore" — etcd restore
  recovers control-plane *state*, it does not move the cluster back to the
  old y-stream's code. Treat the go/no-go decision before starting as final.
- Take the backup **same-day**, immediately before the window — an
  RAM/disk-remediation-era backup (e.g. the one from issue 13) is fine as a
  fallback but should not be the one relied on for the actual window if more
  than a day or two has passed.
- Application/VM persistent data is still **not** covered by etcd backup —
  no Velero/OADP operator is installed on this cluster (gap noted since
  issue 11, still open, does not block a y-stream any more than it blocked
  the z-stream).

---

## 5. Known issues that could arise (grounded in this cluster's actual history)

| Risk | Likelihood here | Evidence | Response |
|---|---|---|---|
| Worker `machine-config-daemon` stalls on image pull | Moderate — happened twice on z-streams (issues 08, 09) | quay.io registry pulls during MCO rollout | Do not panic-restore. Both prior incidents self-recovered via kubelet retry within 10–40 min. Diagnose via `oc get co machine-config` → pod events → `getent hosts quay.io` (issue 08 found an IPv6-only DNS quirk) before considering manual intervention |
| PDB blocks a node drain outright | Confirmed pattern on this cluster's *last y-stream* specifically (issue 02 hit it twice, different PDBs each time) | `openshift-gitops-controller-pdb`, `virt-api-pdb` — **neither exists on this cluster anymore** (no GitOps installed, CNV removed in issue 12), but treat this as "will happen again with whatever PDB is present at the time," not "solved" | Check `oc get pdb -A` before the window (§2); if a drain hangs anyway, check MCO controller logs for `Cannot evict`, delete the specific blocking PDB (operator recreates it), let MCO retry (~5 min cycle) |
| quay.io image pull rate limit hit mid-upgrade | Happened once (issue 02) | Anonymous/under-authenticated pulls during a burst of image pulls | Confirm the cluster pull-secret has authenticated quay.io credentials before starting (§2 script checks this) |
| Post-upgrade channel drift via shared `kubeadmin` | Happened once, unattributable (issue 08) | `kube:admin` audit identity, `Default` audit profile | Use a named admin account (`babus`, issue 10) for every channel/upgrade command; periodically re-check `spec.channel` after the window |
| Bastion `oc` client left behind | Happened once (issue 04), only caught after the fact | Server moves, client binary doesn't | Refresh the bastion `oc`/`kubectl` binary as an explicit post-upgrade step (§6), not an afterthought |
| Master RAM pressure during overlapping-component rollout | Previously a hard blocker (issue 08's Insights finding); remediated 2026-08-26 (issue 13) | Masters raised from ~11GB to 14GB each | Re-confirm same-day headroom in §2 regardless — 14GB is still under Red Hat's stated 16GB control-plane minimum, an accepted risk, not a cleared one |

---

## 6. Post-upgrade validation checklist

Run [`scripts/post-upgrade-validate.sh`](../issues/13-420-upgrade-readiness-ram-remediation-and-prechecks/scripts/post-upgrade-validate.sh)
(expected version as arg) for the automatable items, then:

- [ ] `oc get clusterversion` — target version, `Available=True`, `Progressing=False`, history entry `state=Completed`
- [ ] `oc get co` — all healthy (`Available=True/Progressing=False/Degraded=False`)
- [ ] `oc get nodes -o wide` — all `Ready`, consistent kubelet version matching the new y-stream across all 5 nodes
- [ ] `oc get mcp` — both pools `Updated=True/Updating=False/Degraded=False`
- [ ] `oc get csr | grep Pending` — still zero
- [ ] Web console reachable (`curl -k -o /dev/null -w '%{http_code}' https://console-openshift-console.apps.lab.ocp.local`) → `200`
- [ ] `oc adm top nodes` — compare against the pre-upgrade baseline (§2); confirm no lingering resource pressure after the reboot cycle settles
- [ ] `oc get pdb -A` — spot-check the same PDBs flagged in §2 are back to their normal `allowedDisruptions`
- [ ] `oc get csv -A` — installed operators (`openshift-lightspeed` etc.) still `Succeeded`, not stuck reconciling against the new API surface
- [ ] Refresh the bastion `oc`/`kubectl` client to match the new server version — check with `oc version`
- [ ] `oc get clusterversion version -o jsonpath='{.status.conditions[?(@.type=="Upgradeable")].status}'` — confirms readiness for the *next* upgrade; `False` for the first ~24h is normal, not a failure
- [ ] Re-confirm `spec.channel` is what you expect — check again a day later too, per the channel-drift lesson (issue 08)
- [ ] Document the actual outcome (timing, any incidents hit, resolution) as a new numbered issue in this repo, same pattern as issues 02/08/09

---

## 7. Timeline & approval planning

| When | Activity |
|---|---|
| T-5+ days | Confirm target version on the intended channel; review API deprecation notes for the target release; confirm every installed operator's vendor compatibility statement |
| T-2 days | Same-day-of-window RAM/disk re-check scheduled; circulate to any app owners flagged in §2; get change approval |
| T-1 day | Re-run the pre-flight checklist (§2) in full to confirm nothing drifted |
| T-0 (window) | Fresh etcd backup → execute upgrade → budget 3–5 hours |
| T+0, immediately after | Post-upgrade validation (§6) |
| T+1 day | Re-check `Upgradeable` condition and channel; document outcome in repo; close change ticket |

**Rollback statement for the ticket**: no downgrade path exists for a
y-stream upgrade, full stop. Recovery from a genuine control-plane failure
mid-upgrade is etcd restore only (same procedure as
[z-stream-patch-procedure.md §7d](z-stream-patch-procedure.md#7d-restoration-procedure-control-plane--etcd)),
and that recovers state on the *old* version's control plane — it does not
substitute for a supported downgrade, because none exists.
