# Issue 11 — Cluster Patch Readiness Review: 4.19.42 → 4.19.43 Security Z-Stream

| Field | Detail |
|---|---|
| **Date** | 2026-08-20 |
| **Type** | Change readiness review (planning — not an incident, not yet executed) |
| **Status** | Review complete — **Blocked on availability**, ready to execute once resolved |
| **Scope** | Patch `lab.ocp.local` from 4.19.42 to 4.19.43 (z-stream, security-classified) |
| **Procedure to follow once unblocked** | [checklists/z-stream-patch-procedure.md](../../checklists/z-stream-patch-procedure.md) |

---

## Review Summary

| Area | Status | Finding |
|---|---|---|
| Current cluster health | ✅ Pass | `oc get co` — all ClusterOperators `Available=True/Progressing=False/Degraded=False`; all 5 nodes `Ready`; MCPs not updating |
| **Target availability** | 🔴 **Blocking** | 4.19.43 is **not yet on `stable-4.19`**. Confirmed via a direct, read-only query of the public Cincinnati update graph: it currently exists only in `candidate-4.19`, `fast-4.19`, and `candidate-4.20`. Red Hat has not yet promoted it to stable — this is the sole blocker, decided to wait rather than switch channel or force an explicit `--to=` override |
| Security content | ℹ️ Info | Errata `RHSA-2026:54555` (the `RHSA` prefix confirms this z-stream carries security fixes, not bug-fixes-only). Exact CVE list not restated here — must be read directly from the errata URL and logged in the change ticket before approval, not assumed |
| conditionalUpdates risk | ✅ Pass (as of this review) | `oc get clusterversion version -o json` → `.status.conditionalUpdates` is empty. Must be re-checked immediately before the actual window, since this is target-specific and could change once 4.19.43 becomes visible on `stable-4.19` |
| Resource headroom | ⚠️ Watch, not blocking | `master-3` tightest at 84% memory at time of review; z-stream load is lighter than a y-stream, so not treated as blocking, but recorded as a pre-flight baseline to compare post-patch |
| App/operator compatibility | ⚠️ Action required before window | `kubevirt-hyperconverged-operator.v4.19.33` and `lightspeed-operator.v1.1.2` installed — both need vendor-side compatibility confirmation for 4.19.43 specifically, not assumed from being same-y-stream. CNV has running VM infrastructure (`virt-api-pdb` etc.) — VM inventory (`oc get vmi -A`) and owner coordination required before scheduling, since VMs need live-migration or explicit stop/start handling during worker drains, unlike stateless pods |
| Backup/restore readiness | 🔴 **Gap noted, not blocking this patch specifically** | etcd backup procedure is proven (issue 08) and covers control-plane state. **No Velero/OADP operator is installed** — application/VM persistent data has no in-cluster backup path independent of etcd. Documented as an open item; does not block this particular z-stream but should be closed before this cluster relies on the restore plan for anything beyond control-plane recovery |
| Recurring risk pattern | ℹ️ Info, carried forward | This cluster has hit the same failure category twice on prior z-streams — a worker `machine-config-daemon` image-pull stall during MCO rollout (issues 08, 09), different specific mechanism each time, both self-recovered without manual restore. Treated as a known, moderately-likely-to-recur risk with defined decision thresholds in the checklist, not a reason to delay this patch |
| External reference review | ✅ Done | Red Hat's official ["Preparing to update a cluster"](https://docs.redhat.com/en/documentation/openshift_container_platform/4.19/html/updating_clusters/preparing-to-update-a-cluster) doc blocks automated fetch (403) — flagged for manual cross-check, not incorporated by guesswork. [kubernetes.recipes' OCP update explainer](https://kubernetes.recipes/recipes/configuration/openshift-cluster-update-process-explained/) was fetchable and added real mechanics (CVO Runlevels, MCO drain sequence, duration formula) — folded into the checklist |

**Verdict**: the cluster and the plan are both ready. The only blocker is
that Red Hat hasn't promoted 4.19.43 to `stable-4.19` yet. No action needed
beyond periodically checking `oc adm upgrade` until it appears, then
executing per the linked checklist.

---

## Decision Made

Chosen path (of three considered): **wait for `stable-4.19` promotion**,
rather than temporarily switching to `fast-4.19` or forcing an explicit
`--to=4.19.43` override while still on `stable-4.19`. Reasoning: safest
option, avoids another channel-spec change so soon after the attribution
incident in issue 08, and this is a routine security patch, not an urgent
one requiring the faster/less-soaked path.

---

## Next Steps

1. Periodically check `oc adm upgrade` for 4.19.43 to appear as recommended on `stable-4.19`.
2. Once visible: run the pre-flight checklist in [z-stream-patch-procedure.md](../../checklists/z-stream-patch-procedure.md) §6, get change-ticket approval per §9's timeline.
3. Execute per the checklist §5–§7.
4. Log the actual outcome as a new issue (would be **12**) — same pattern as issue 10 documenting the `babus` onboarding execution — rather than editing this readiness review after the fact.
