# App/DB Compatibility + Team Coordination — the Other Half of an OCP Upgrade

> **Why this doc exists:** the platform upgrade can go perfectly — all 34
> operators green, every node rebooted clean — and the change can *still* be
> a failure in banking terms because the payments app won't start on the
> new Kubernetes version, a DB connection storm hits during worker drains,
> or the security team never got the CVE evidence they need to close the
> audit item. Platform health is the necessary half; **app/DB compatibility
> and human coordination are the other half.** This doc is the OCP cluster
> SME's playbook for that half: what to verify per application and database,
> and exactly who does what, when.

---

## Part 1 — The SME's role, stated plainly

As the OCP cluster SME you are the **orchestrator, not the doer of
everything**. Your job during an upgrade is:

1. Own the platform itself end-to-end (the runbook in
   [AIRGAP-UPGRADE-GUIDE.md](AIRGAP-UPGRADE-GUIDE.md) — that's yours alone)
2. **Extract commitments from every other team** — each team's
   deliverable to this change is defined below; your job is collecting
   them on time, not doing their work for them
3. Run the window: sequence, checkpoints, abort calls (with the declared
   authority), comms
4. Produce the evidence pack that closes the change for audit

A change that relies on the platform SME *personally* testing every app
is a change that fails the first time you're on vacation. The SME
verifies that each owner tested — they don't replace the owner.

---

## Part 2 — Who plays which role (role-by-role detail)

### 2.1 OCP Platform Team (you + peers)

**Owns:** cluster version, operators, nodes, etcd, mirror registry, the
upgrade mechanics, platform smoke tests.

- *Before:* everything in the main runbook (health gates, backup,
  mirroring, cluster wiring). Plus: build the **app inventory** (Part 3),
  circulate it, schedule all checkpoints.
- *During:* drive `oc adm upgrade`, monitor, call stage checkpoints on the
  bridge, pause/resume as needed. You speak; others report.
- *After:* platform validation, evidence collection, CRQ closure,
  post-mortem/issue write-up (this repo's convention).

### 2.2 Application Owners / Dev Teams

**Owns:** whether *their* app works on the target version — you can't know
that, they can't not know it.

What you need from each of them, in writing, by **T-7d**:

| Deliverable | What it looks like |
|---|---|
| Compatibility statement | "App X runs fine on OCP 4.21 / K8s 1.34 — we tested in UAT" OR a list of their concerns |
| API usage check | Confirmation they're not calling APIs removed in 4.21 (you give them the list + the `apirequestcounts` evidence) |
| Smoke test | A **named test with an expected result** they will run inside the window — e.g. "POST /payments/health returns 200 + processes a test txn" — and who runs it |
| Drain tolerance | Replica count ≥2 + working PDB, OR explicit acceptance of a brief outage during their worker's drain |
| Contact | Name + phone for the window bridge — not "the team email" |

*During:* they run their smoke test when you call the app-validation
checkpoint; they report PASS/FAIL on the bridge, not over email later.

*After:* confirm business-as-usual or escalate a regression through the
incident process — not a side channel.

### 2.3 DBA Team

**Owns:** everything with real data — and the subtlety here is splitting
"the database" into two cases, because they fail differently:

**Case A — DB outside the cluster** (Oracle/DB2/MSSQL on VMs, mainframe
connectors): the OCP upgrade can't break the DB, but *drains break
connections to it*. Their deliverables:

- Confirm app connection pools/drivers tolerate dropped connections during
  worker drains (retry/backoff configured, not hard-fail)
- Flag any scheduled batch/maintenance that must not collide with the
  window — a DB maintenance running mid-upgrade is a classic avoidable
  outage cause
- Verify the *last good backup* of critical DBs exists and is restorable
  (independent of the OCP etcd backup — different blast radius)

**Case B — DB inside the cluster** (Postgres/MySQL operators, Redis —
see [issue 15](../15-redis-app-db-gitops-deployment/README.md), MongoDB):
now the DB rides the upgrade:

- **Operator compatibility with 4.21** — the DB operator itself must
  support the target OCP/K8s version; check the vendor's compatibility
  matrix, same as any OLM operator
- **Failover behavior during drains** — if it's a replicated DB with a
  primary+replicas spread across workers, draining a worker can trigger
  an unplanned failover. Agree on the expected behavior and how they'll
  validate replication health post-drain
- **Backup/restore verified** — their own DB backup, tested, within 24h
- PVCs Bound and healthy (`oc get pvc -A`) — your side of it

### 2.4 Security / Compliance Team

**Owns:** risk sign-off and audit evidence.

- Review the errata/CVE list for the target release (you supply the RHSA
  links — `access.redhat.com/errata`, search the release) and issue the
  security approval *before* CAB
- State the evidence they need retained: upgrade logs, clusterversion
  history, etcd backup checksum, the admin-acks ConfigMap change — you
  collect it in Phase 6 of the runbook, they consume it
- If they run scanners/agents on the cluster (Falco, ACS, Qualys,
  CrowdStrike), confirm agent compatibility with the new RHCOS/k8s
  version — a host agent that panics nodes during the rollout is a real
  failure mode, not a theoretical one

### 2.5 Change Manager / CAB

**Owns:** the authorization itself.

- You bring: the CRQ with runbook attached, rollback criteria, blast
  radius statement, and every team's sign-off collected
- They bring: the approved window, the authority to proceed or abort, and
  they enforce "no changes outside this CRQ during the window"

### 2.6 Network / Load-Balancer Team

**Owns:** the edges traffic crosses — and one edge people forget in
airgap: **the route to your mirror registry**.

- Confirm nodes can reach `mirror.bank.local:8443` — firewall rules for
  registry traffic on every node, not just the bastion
- Ingress/router VIPs and MetalLB pools survive reboots (they do by
  design — but if F5/external LB health-probes are misconfigured, nodes
  mid-reboot still receive traffic)
- DNS for the mirror resolves cluster-wide
- If you run an external LB in front of the API (like this lab's HAProxy —
  see [issue 28](../28-load-balancer-planning-design/README.md)), confirm
  its health checks drain masters gracefully during the master reboot
  sequence

### 2.7 Storage / Backup Team

**Owns:** PV backing and data protection tooling.

- NFS provisioner / CSI driver compatibility with 4.21 (your
  `nfs-provisioner` namespace is exactly this)
- OADP/Velero or storage-snapshot backups green in the last 24h, restore
  *tested* — see [issue 30](../30-app-db-backup-dr-planning/README.md)
- Enough PV/backend headroom — an upgrade that stalls because a
  snapshot-at-drain filled the backend is embarrassing and preventable

### 2.8 NOC / Monitoring

**Owns:** eyes and paging.

- Apply the alert silences you specify (Phase 2.4 of the runbook) —
  drain/reboot noise must not page the on-call into a false incident
- Keep the live dashboards open on the bridge; report anomalies *they*
  see (a metric nobody's watching is a metric that didn't exist)
- Remove silences at window close and confirm normal alerting resumed

### 2.9 Vendor / Support

**Owns:** escalation when your own depth runs out.

- Red Hat: open a **proactive "heads-up" case** before the window for
  banking-critical changes (standard practice — severity can be normal;
  it pre-warms context if you need to escalate mid-window). In airgap
  environments attach the `must-gather` *before* the window if the case
  asks for it — you can't collect it if the cluster's down.
- Third-party vendors (LB, agents, DB, monitoring tools): named contact +
  support contract numbers on the bridge roster.

### 2.10 Incident Commander / Release Manager (the window itself)

On the day, someone other than you holds the *business* authority — you
hold the *technical* authority. They're the voice that calls "we're
aborting" per the agreed criteria; you're the voice that says "the
cluster is safe to continue" or "we must stop." If you're both, name a
deputy — one person can't watch a 6-hour window alone and also make clean
judgment calls at hour 5.

---

## Part 3 — App/DB compatibility workstream (the "how", concretely)

This is the technical checklist you drive the app/DBA teams through —
in parallel with your own platform pre-flight, not after it.

### 3.1 Build the inventory (T-14d)

```bash
# Everything deployed, by namespace — your starting census
oc get deploy,sts,ds -A -o wide
oc get csv -A                              # installed operators
oc get pdb -A                              # drain-blocking budgets
oc get pvc -A                              # stateful workloads
oc get routes -A 2>/dev/null               # externally-reachable apps
```

→ Produce a table: app, namespace, owner, replicas, PDB?, stateful?,
DB dependency (internal/external), criticality. Every row needs an
*owner* — a row with no owner is a risk, not a footnote.

### 3.2 The compatibility matrix each owner fills (T-14d → T-7d)

| Check | How they verify | Evidence you want |
|---|---|---|
| K8s API removals | You give them the `apirequestcounts` output + the 4.21 removed-API list; they grep their manifests/dependencies | "No removed APIs in use" per app |
| Operator/DB operator cert | Vendor compatibility matrix for OCP 4.21 | Link/screenshot to vendor statement |
| Agent/sidecar compat | EDR, monitoring, service-mesh sidecars on their pods vs. new K8s/RHCOS | Vendor statement per agent |
| TLS/ciphers | Any hardcoded cipher/protocol in their ingress or app config vs. what 4.21 negotiates | Smoke test covers real TLS path |
| Drain tolerance | replicas ≥2 + PDB, or accepted outage | Their written acceptance |
| Registry access (airgap!) | Their images exist in the internal registry — a new app dependency on an *external* image will fail to pull | `oc describe pod` on their pods shows internal refs only |

### 3.3 The smoke-test contract (collect by T-3d)

One line per app, in the CRQ itself:

```
APP: payments-api   OWNER: J.Smith (+1-555-0100)
TEST: POST https://<route>/health + test txn $0.01 → expect HTTP 200 + txn id
RUN BY: J.Smith    WHEN: checkpoint "app-validation" (after worker-1 drain + at final)
FAIL ACTION: declare regression → incident bridge, do NOT proceed to final close
```

A smoke test that isn't this specific is a rumor, not a test.

### 3.4 Inside the window — the app-validation checkpoints

Two of them, baked into the runbook's checkpoint table:

1. **After first worker drains** — proves drain rescheduling works on the
   real apps before the second worker goes
2. **After full rollout** — final green-light before you close

Owners run their contracted tests *live on the bridge* — results spoken,
not promised by email.

---

## Part 4 — Upgrade RACI (who does what, when)

*R = does the work, A = owns the outcome, C = consulted, I = informed.
One A per row.*

| # | Activity | OCP SME | App/Dev | DBA | Security | CAB/Chg | Network | Storage | NOC | Incid. Cmdr |
|---|---|---|---|---|---|---|---|---|---|---|
| 1 | Readiness assessment + target selection | **A**/R | C | C | C | I | C | C | I | I |
| 2 | App/API compatibility sign-off | C | **A**/R | C | I | I | I | I | I | I |
| 3 | DB compat + backup verification | C | C | **A**/R | I | I | I | C | I | I |
| 4 | Security errata review + approval | C | I | I | **A**/R | C | I | I | I | I |
| 5 | Mirror registry + oc-mirror content | **A**/R | I | I | I | I | C | C | I | I |
| 6 | etcd + state capture backup | **A**/R | I | C | I | I | I | C | I | I |
| 7 | Change approval (the window itself) | R | I | I | C | **A** | I | I | I | I |
| 8 | Mirror firewall/DNS reachability | C | I | I | I | I | **A**/R | I | I | I |
| 9 | Alert silences | C | I | I | I | I | I | I | **A**/R | I |
| 10 | Execute `oc adm upgrade` + monitor | **A**/R | I | I | I | I | I | I | C | I |
| 11 | App smoke tests (both checkpoints) | C | **A**/R | C | I | I | I | I | C | I |
| 12 | Abort decision per declared criteria | C | C | C | C | C | I | I | I | **A**/R |
| 13 | etcd restore (if invoked) | **A**/R | I | C | I | I | I | C | I | C |
| 14 | Post-upgrade validation (platform) | **A**/R | C | C | I | I | C | C | C | I |
| 15 | Evidence pack + CRQ closure | **A**/R | I | I | C | C | I | I | I | I |
| 16 | Post-incident write-up / RCA | **A**/R | C | C | C | I | C | C | I | I |

---

## Part 5 — Coordination cadence (the actual calendar)

| When | Event | Output |
|---|---|---|
| T-14d | Kickoff: you circulate app inventory + this doc | Every app has an owner + the matrix to fill |
| T-7d | Compatibility review: owners return the matrix + smoke contracts | Blockers surfaced while there's still time |
| T-3d | Go/No-Go: all sign-offs in; runbook re-read on a call | CAB-ready packet |
| T-1d | Pre-flight re-run (script + manual) | Gate PASS |
| T-0 | Window: checkpoints called on the bridge, owners test live | Executed change |
| T+1d | Close-out: evidence pack, CRQ closed, issue written up | Audit-ready record |

**Bridge protocol during the window:** one voice (you) driving steps;
each team reports only when called or when they have a FAIL; status
updates every 30 min even if "nothing to report" — silence breeds
parallel improvisation, which is how upgrades get *worse*.

---

## Part 6 — The failure modes this prevents

| Failure without coordination | What the coordination prevents |
|---|---|
| App using a removed K8s API fails post-upgrade | 3.2 matrix — caught at T-7d in UAT, not in prod |
| DB connection storm/outage during worker drain | DBA Case-A check + drain tolerance column in inventory |
| Security blocks the change at CAB for missing evidence | Their deliverables defined at T-14d, collected at Phase 6 |
| Nodes can't reach the mirror mid-rollout | Network team's firewall/DNS check is a *named row* (row 8), not an assumption |
| Alert storms page the wrong on-call | NOC owns silences — row 9 |
| Everyone assumes someone else tested the app | Smoke-test contract: named test, named human, defined fail action |
| Abort called (or not called) by vibes | Declared criteria + a named Incident Cmdr (row 12) |
| "We thought OCP team would also fix our app" | The RACI: app validation is **A** on the app owner — you are C |
