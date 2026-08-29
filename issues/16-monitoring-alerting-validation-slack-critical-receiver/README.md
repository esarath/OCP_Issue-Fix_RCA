# Issue 16 — Monitoring/Alerting Deep-Dive Validation + Slack Receiver for Critical Alerts

| Field | Detail |
|---|---|
| **Date** | 2026-08-29 |
| **Type** | Validation + Enhancement (Change Execution) |
| **Status** | **Completed.** Full monitoring/alerting stack validated healthy; `Critical`-severity Alertmanager route wired to a Slack Incoming Webhook and confirmed delivering (synthetic test alert received in Slack, `alertmanager_notifications_failed_total{integration="slack"}` = 0). |
| **Scope** | `openshift-monitoring` namespace on `lab.ocp.local` — Prometheus, Alertmanager, Thanos Querier, PrometheusRules, ClusterOperators |
| **Target Secret** | `alertmanager-main` (`openshift-monitoring`) |

---

## Summary

Two-part exercise: (1) a full health/architecture validation pass over the platform monitoring stack, and (2) closing a real gap found during it — the `Critical` severity route in Alertmanager existed in the routing tree but had no receiver backend wired up, so critical alerts were never leaving the cluster.

## Part 1 — Monitoring stack validation

**Component health**
- All `openshift-monitoring` pods (Prometheus ×2, Alertmanager ×2, Thanos Querier ×2, kube-state-metrics, node-exporter ×6, telemeter-client, monitoring-plugin, prometheus-operator, cluster-monitoring-operator) `Running` and fully ready.
- `monitoring` ClusterOperator: `Available=True` / `Degraded=False` / `Progressing=False` (stable 10d at time of check). All 34 ClusterOperators clean — no cascading issues.
- Alertmanager/Prometheus/Thanos Querier routes reachable externally (`401` on unauthenticated probe = OAuth proxy enforcing auth correctly, not a DNS/TLS problem — see [issue 07](../07-recurring-cert-expiry-cron-blindspot/) for what an actual cert/DNS failure looks like on this cluster).

**Architecture facts confirmed**
- Prometheus: `replicas: 2`, `retention: 15d`, PVC-backed (`nfs-storage`, 20Gi × 2, bound 150d) — durable across pod reschedule.
- Alertmanager: `replicas: 2`, `retention: 120h`, **no PVC** (`storage: null`, no PVC exists) — silences/notification log live only in pod memory + inter-replica gossip sync. If both replicas restart together, that state is lost. Confirmed by an existing permanent silence (KubeVirt PDB alerts, `endsAt: 3000-01-01`, created by `hyperconverged-cluster-operator`) that depends on this.
- `enableUserWorkload: true` in `cluster-monitoring-config` — confirmed by a live custom rule from [issue 15](../15-redis-app-db-gitops-deployment/)'s Redis deployment (`redis-platform/redis-pdb-alerts: RedisPodDisruptionBudgetUnhealthy`).
- 48 `PrometheusRule` objects, 36 individual `severity=critical` alert rules spanning etcd, kube-apiserver, kube-scheduler, kube-controller-manager, OVN-Kubernetes, ingress, storage, MCO, plus the one custom Redis rule above — all of these now reach Slack via the fix below.
- **Watchdog** canary (`vector(1)`, `severity: none`, defined in `cluster-monitoring-operator-prometheus-rules/general.rules`) confirmed firing continuously — proves the full rule-eval → Alertmanager → receiver pipeline is alive end-to-end, independent of any single alert.
- No `resources.limits` set on either Prometheus or Alertmanager, only `requests` — acceptable for a lab cluster, flagged for prod parity.

**Alerts firing at time of review** (none required action)

| Alert | Namespace | Severity | Note |
|---|---|---|---|
| `PodDisruptionBudgetAtLimit` | redis-platform | warning | Expected — Redis GitOps deployment paused/scaled to 0 during that shutdown window |
| `TelemeterClientFailures` | openshift-monitoring | warning | Expected in a disconnected lab — no path to Red Hat's telemetry endpoint |
| `SamplesImagestreamImportFailing` | openshift-cluster-samples-operator | warning | `jenkins`/`jenkins-agent-base` imagestream imports failing — no route to the upstream registry from this lab |
| `PodSecurityViolation` | openshift-kube-apiserver | info | Informational only |

## Part 2 — Gap found: `Critical` route had no receiver

The routing tree already had the right shape, it just wasn't finished:

```yaml
route:
  receiver: Default
  routes:
  - receiver: Watchdog
    matchers: [alertname="Watchdog"]
  - receiver: "null"
    matchers: [alertname="InfoInhibitor"]
  - receiver: Critical
    matchers: [severity="critical"]
receivers:
- name: Default
- name: Watchdog
- name: Critical   # <- existed, but had zero notification config behind it
- name: "null"
```

Every `severity=critical` alert (all 36 rules above) was matching this route and then going nowhere — visible only via console/API, no external notification. `Default`/`Watchdog`/`null` receivers were untouched by this fix; only `Critical` gained a `slack_configs` block.

### Fix applied

Added a receiver-scoped (not global) `slack_configs` entry to the `Critical` receiver in the `alertmanager-main` Secret's `alertmanager.yaml`:
- `api_url`: a Slack Incoming Webhook, provisioned via a dedicated Slack App (`ocp-alertmanager`) → Incoming Webhooks feature, scoped to a single pre-chosen channel. Deliberately **not** a bot token / app-level token / OAuth token — those don't work with Alertmanager's native Slack integration and carry far broader privilege than needed here.
- `send_resolved: true` — Slack gets a follow-up when the alert clears, not just when it fires.
- `channel` intentionally **omitted** — defaults to whatever channel the webhook itself was scoped to at creation, one less thing to keep in sync if the channel changes.
- Custom `title`/`text`/`color` templates surfacing `alertname`, `severity`, `namespace`, `summary`, `description`, and `runbook_url` (most platform critical rules — e.g. `PodDisruptionBudgetAtLimit`, `etcd*`, `Kube*Down` — carry a `runbook_url` annotation; the default Slack template drops it).
- Scoped to the `Critical` receiver only, not `global.slack_api_url` — keeps blast radius minimal if another receiver is misconfigured later.

The webhook URL itself is intentionally **not recorded anywhere in this repo** — it lives only in the `alertmanager-main` Secret in-cluster. Anyone rotating it just needs to `oc edit secret alertmanager-main -n openshift-monitoring` (or repeat the procedure below) and update the one `api_url` line.

### Validation performed (all before touching the live cluster, then confirmed after)

1. `amtool check-config` against the modified YAML inside the `alertmanager-main-0` pod (container filesystem is read-only except the PVC-backed `/alertmanager` data dir — used that as the scratch path) → `SUCCESS`, 4 receivers, 3 inhibit rules.
2. `amtool config routes test` — confirmed routing logic unaffected for everything except the target case:
   - `severity=critical` → `Critical` ✅ (the intended change)
   - `severity=warning` → `Default` (unchanged)
   - `alertname=Watchdog` → `Watchdog` (unchanged)
3. Backed up the pre-change Secret content locally before applying (not committed to this repo — operational backup only).
4. Applied via `oc create secret generic alertmanager-main ... --dry-run=client -o yaml | oc replace -f -` (never a blind `oc edit`).
5. Confirmed `config-reloader` sidecar picked up the change on **both** Alertmanager replicas (`alertmanager_main-0` and `-1`) — checked `/api/v2/status` on each pod directly, `slack_configs` present in both; no `AlertmanagerFailedReload` alert fired.
6. Fired a synthetic test alert directly at the Alertmanager API via `amtool alert add alertname="OCPAlertmanagerSlackWireupTest" severity="critical" ...` (5-minute TTL, auto-resolved) — confirmed it routed to the `Critical` receiver (`"receivers":[{"name":"Critical"}]` in `/api/v2/alerts`).
7. Confirmed delivery via Alertmanager's own metrics: `alertmanager_notifications_total{integration="slack"} = 1`, all `alertmanager_notifications_failed_total{integration="slack",...}` counters at `0`.
8. User visually confirmed the test message landed in the target Slack channel.

### Process note / lesson learned (no secrets recorded)

While collecting the webhook, several *wrong* Slack credentials (a workspace invite link, a user OAuth/refresh token, a bot token, and an app-level token) were pasted into chat before the correct Incoming Webhook URL was found — none of those are usable by Alertmanager's Slack integration, and several were far more privileged than needed. None were used or written to any file; the user was advised to revoke/rotate each one. For any future credential handoff during an interactive session: write the value to a local file with `chmod 600` and hand off the file path/channel name instead of pasting the raw value into chat — keeps it out of the conversation transcript entirely. Applied for the actual webhook value on this pass.

## Related

- [Issue 07](../07-recurring-cert-expiry-cron-blindspot/) — what an actual DNS/cert-driven monitoring-route failure looks like on this cluster, for contrast with the healthy `401` responses seen here
- [Issue 14](../14-419-to-420-upgrade-execution/) — cluster upgraded to 4.20.35, the version this validation was run against
- [Issue 15](../15-redis-app-db-gitops-deployment/) — source of the custom `redis-platform` PrometheusRule and the `PodDisruptionBudgetAtLimit` alert seen firing during this review

## Open follow-ups (not done in this pass)

- Alertmanager has no PVC — consider `alertmanagerMain.volumeClaimTemplate` in `cluster-monitoring-config` if silence/notification-log durability across simultaneous replica restarts becomes a real requirement.
- `warning`/`info` severity alerts still have no external notification path (console/API only) — only `critical` was in scope for this pass.
- No `resources.limits` on Prometheus/Alertmanager — fine for this lab, worth revisiting if this cluster is ever used as a prod-parity reference.
