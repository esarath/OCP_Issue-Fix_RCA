# Technical Leadership Playbook — Day-0 Architecture → Day-2 Operations

A repeatable framework for leading high-value, technically complex platform engagements (OpenShift and comparable). Written for the person accountable for the *technical outcome*, not just the technical work.

> Placeholders in `<angle brackets>` — replace before use. Templates referenced live in `templates/` and `checklists/`.

---

## Table of Contents

1. [The Day-0/1/2 model](#part-0--the-day-012-model)
2. [Operating principles](#part-1--operating-principles)
3. [What the technical lead owns](#part-2--what-the-technical-lead-owns)
4. [Day-0 — architecture & design](#part-3--day-0--architecture--design)
5. [Day-1 — build, deploy & validate](#part-4--day-1--build-deploy--validate)
6. [Day-2 — operate, optimize & hand off](#part-5--day-2--operate-optimize--hand-off)
7. [Cross-cutting practices](#part-6--cross-cutting-practices)
8. [Anti-patterns that kill engagements](#part-7--anti-patterns)
9. [Success metrics](#part-8--success-metrics)

---

## Part 0 — The Day-0/1/2 model

| Phase | Question answered | Ends when |
|---|---|---|
| **Day-0** | "What are we building and why — and will it work?" | Design approved, risks registered, build plan exists |
| **Day-1** | "Build it." | Running in production (or prod-parity), acceptance criteria met |
| **Day-2** | "Keep it running — and keep it yours." | Customer operates independently; runbooks, monitoring, DR proven |

High-value engagements are won or lost at the **phase boundaries**. The two gate artifacts that matter most: a signed-off design (Day-0→1) and a completed handoff (Day-1→2). Everything in this playbook feeds those gates.

## Part 1 — Operating principles

1. **Write it down or it didn't happen.** Architecture, decisions, risks, RCAs — in a repo (this repository is the pattern), not in chat threads and memory.
2. **Decisions are artifacts.** Every consequential choice gets an ADR (`templates/architecture-decision-record.md`) — context, options, decision, consequences. Future-you and the customer will ask "why?" long after the meeting.
3. **Requirements before solutions.** A design that answers an unasked question is the most expensive artifact in consulting. Discovery first (Part 3.1).
4. **Prove reversibility.** Every change has a rollback path written *before* execution — see Issue 26's rollback section for the pattern.
5. **Day-2 is designed at Day-0.** Monitoring, patching, DR, cert expiry, identity lifecycle are *design inputs*, not afterthoughts. If it's not in the HLD, it won't exist on Day-30.
6. **The customer must be able to run it without you.** Self-sufficiency is the deliverable; hero dependency is the failure mode.
7. **Small blast radius, big confidence.** Pilot → canary → production. Every phase has an exit criterion, not a vibe.

## Part 2 — What the technical lead owns

| Responsibility | Day-0 | Day-1 | Day-2 |
|---|---|---|---|
| Requirements & NFRs | **Own** — elicit, document, get sign-off | Validate against | Hand to ops |
| Architecture & design docs | **Own** — HLD/LLD + ADRs | Maintain as-built deltas | Update on change |
| Risk register | **Own** | Burn down | Transfer open items |
| Build/deploy execution | Plan | **Own/direct** | Automate + document |
| Validation & acceptance | Define criteria | **Own** | Regression on changes |
| Stakeholder comms | **Own** cadence | Own | Transition to customer |
| Ops runbooks & RCA culture | Design for | Seed | **Own the handoff** |
| Team upskilling | Assess | Pair/do-together | **Own** — KT is a deliverable |

The lead's scarcest resource is attention — spend it at gates, on decisions, and on the customer's capability, not on tasks the team can do.

## Part 3 — Day-0: architecture & design

### 3.1 Discovery — before any diagram

Run structured discovery (`templates/discovery-questionnaire.md` for the full questionnaire). Minimum viable answers:

| Domain | Must capture |
|---|---|
| **Business** | What outcome? Deadline driver? Cost of downtime? Compliance regime? |
| **Workload** | Apps count/type, statefulness, sizing, growth, burst patterns |
| **Platform** | Existing infra (hypervisor, storage, network), DNS/PKI, identity (LDAP/AD — Issue 26), LB estate (F5/AVI/HAProxy — Issue 28) |
| **Operations** | Who runs it? Skill level? Change windows? Existing monitoring/ticketing? |
| **Constraints** | Air-gap? GPU? Latency? Data residency? Budget? |
| **NFRs** | Availability target (99.9 vs 99.95), RTO/RPO, throughput, security baseline |

**Anti-pattern**: accepting "we want Kubernetes" as a requirement. Dig to the workload and the operational reality.

### 3.2 Architecture synthesis — the decision set

For an OCP engagement the HLD must make explicit calls on:

| Area | Key decisions | Repo reference |
|---|---|---|
| Topology | masters/workers count, HA model, zones | — |
| Networking | CNI (OVN), ingress strategy, LB layers, egress | Issue 28 |
| Identity | IdP (LDAP/AD), group→RBAC model, break-glass | Issue 26 |
| PKI/certs | Internal CA, route certs, rotation | Issue 25 |
| Storage | Classes, provisioner, reclaim policy | Issue 23 |
| Monitoring | Retention, alerting routes, sizing | Issues 16/22/24 |
| DR/backup | etcd snapshots, off-box, RTO/RPO | Issue 27 |
| Upgrade/patch | Channel, cadence, maintenance windows | Issues 8/13/14/21 |
| GitOps/app delivery | ArgoCD vs pipelines vs both | Issues 15/19/20 |

### 3.3 Design artifacts that must exist

| Artifact | Purpose | Template |
|---|---|---|
| **HLD** | Architecture decisions + rationale for approvers | — |
| **LLD** | Object-level detail engineers can execute | — (Issue 15 is an example) |
| **ADRs** | One per consequential choice | `templates/architecture-decision-record.md` |
| **Risk register** | Known risks + owner + mitigation + status | `templates/risk-register.md` |
| **Readiness checklist** | Preconditions verified before build | `checklists/day0-day1-gates.md` |
| **Acceptance criteria** | Objective tests defining "done" | — |

### 3.4 The Day-0 exit gate

Do not start Day-1 until: (1) HLD approved by customer stakeholders *in writing*, (2) NFRs quantified, (3) risk register reviewed, (4) build prerequisites confirmed available (network, DNS, LB VIPs, storage, creds), (5) rollback strategy stated.

## Part 4 — Day-1: build, deploy & validate

| Practice | How |
|---|---|
| **Rehearse** | Build in lab/POC first; every production step should be a re-run of a tested runbook — never first execution in prod |
| **Infrastructure as the deliverable** | Manifests/Helm/GitOps in a repo the customer owns — not snowflake CLI history (this repo's `manifests/` pattern) |
| **Stage the rollout** | Control plane → infra services (auth, LB, monitoring) → pilot workload → remaining workloads. Each stage has a pass/fail check |
| **Validate continuously** | Automated smoke checks after every stage (`scripts/*-health-check.sh` pattern from Issues 25/27/28) |
| **Cutover with a plan** | Freeze window, DNS/VIP switch, pre-staged rollback, comms bridge staffed |
| **Document as-built** | Update the design docs to match reality before leaving the room |

## Part 5 — Day-2: operate, optimize & hand off

Day-2 is where engagements are remembered. The ops model must cover:

| Operational domain | Must exist | This repo's example |
|---|---|---|
| Monitoring & alerting | Dashboards, alert routing to *someone who acts*, capacity signals | Issues 16, 22, 24 |
| Patching/upgrades | Cadence, pre/post-check checklists, rollback | Issue 21 + `checklists/` |
| Backup & DR | Tested restore — a restore never rehearsed is not a plan | Issue 27 |
| Certificate lifecycle | Rotation automation or calendar alerts | Issue 25 |
| Identity lifecycle | Joiner/leaver via central IdP | Issue 26 |
| Capacity & performance | Sizing reviews, scaling playbook | Issue 22 |
| Incident response | RCA convention — symptom→cause→fix→prevention | This entire repo |
| Runbooks | Per-component operational docs | `issues/` README pattern |

### The handoff gate (Day-1→2 → exit)

Complete `checklists/day2-handoff.md`. Non-negotiables:

- [ ] Customer engineer has executed each runbook **themselves**, observed
- [ ] Monitoring alerts reach the customer, not you
- [ ] A restore has been performed by the customer at least once
- [ ] All credentials/secrets transferred into customer secret management
- [ ] Open risks formally accepted by a named customer owner
- [ ] RCA/repo handed over with the "how to add an issue" convention (root README Part)

## Part 6 — Cross-cutting practices

| Practice | Cadence/method |
|---|---|
| Stakeholder map | Day-0: identify decision-maker, blocker, champion, and the person who'll run it |
| Comms cadence | Weekly written status: progress / risks / decisions needed / next milestones. Written > verbal — it forces precision |
| RACI | Per workstream — one **A** per row (see the F5 split in Issue 28's appendix: network vs platform team) |
| Escalation path | Agreed Day-0: technical blocker → named contact with SLA; never discover it mid-incident |
| Decision log | ADRs + a running decision table in the weekly status |
| Parking lot | Out-of-scope requests logged, not silently absorbed — scope creep is a leadership failure, not a delivery one |
| KT philosophy | Pair, don't present. The customer types; you narrate. Record once, reuse forever |

## Part 7 — Anti-patterns

| Anti-pattern | What it looks like | Correction |
|---|---|---|
| Hero consulting | Only you can run it | Pair + handoff gate |
| Gold-plating | Architecture bigger than the workload | Re-derive every component from an NFR |
| Silent scope absorption | "Small favors" accumulate | Parking lot + change control |
| Design without discovery | Solution in search of requirement | Back to questionnaire |
| Day-2 as an afterthought | No monitoring/DR at go-live | Day-2 items are Day-0 design inputs |
| Oral architecture | Decisions live in meetings | ADRs |
| Green dashboards | Status reports hide risk | Risks section mandatory, even when empty |

## Part 8 — Success metrics

| Metric | Target |
|---|---|
| Acceptance criteria pass rate at Day-1 gate | 100% or documented exceptions |
| Sev-1/2 incidents in first 30 days of Day-2 | 0 design-caused |
| Customer executes top-5 runbooks unaided | Before exit |
| Time-to-restore (DR drill) | Within stated RTO |
| Open risks at exit | All accepted by named customer owner |
| Documentation completeness | Every issue has README+RCA; every decision has an ADR |

---

## Bottom line

```
Day-0:  earn the right to build    — discovery, design, ADRs, risks, sign-off
Day-1:  build it boring            — rehearsed runbooks, staged rollout, gates
Day-2:  make yourself unnecessary  — ops model, KT, proven DR, clean handoff
```
