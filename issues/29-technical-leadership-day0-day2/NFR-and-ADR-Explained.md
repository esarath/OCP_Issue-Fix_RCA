# NFRs & ADRs Explained — with worked examples from this repo

Two artifacts that separate professional architecture from improvised one. NFRs say *how well* the system must work; ADRs record *why* you built it the way you did.

---

## Part 1 — Non-Functional Requirements (NFRs)

### What they are

Functional requirements describe **what** the system does ("users log in with AD credentials"). NFRs describe **how well** it must do it — the "-ilities": availability, performance, security, recoverability, scalability, operability.

| Functional req | The NFRs hiding behind it |
|---|---|
| "Expose Jenkins externally" | availability %, TLS required, p95 latency, RTO on router failure |
| "Centralize auth via AD" | login latency, IdP failover, leaver-revocation SLA |
| "Take etcd backups" | RPO (how much data loss is tolerable), RTO (how fast must we be back) |

### Why they matter on OCP

Nearly every cluster design decision is an NFR answer:

| NFR | Design decision it drives | This repo |
|---|---|---|
| Availability 99.9% | 3 masters (tolerate 1), router on both workers, `maxUnavailable: 0` rollouts | Issue 28 |
| RPO ≤ 24h / RTO ≤ 1h | Daily `cluster-backup.sh` + off-box copy + rehearsed restore | Issue 27 |
| Security baseline | LDAPS not LDAP, `insecure: false`, edge TLS, tight route RBAC | Issues 25, 26 |
| Operability | Group-sync automation, cert auto-rotation, named-user audit | Issues 25, 26 |
| Capacity | PVC sizing, monitoring replica/memory envelope | Issues 22, 23 |

### How to write a good NFR

The test: **can you write a pass/fail test for it?**

| Bad (a wish) | Good (a requirement) |
|---|---|
| "Must be highly available" | "99.9% monthly availability; tolerate loss of any single node" |
| "Must be fast" | "p95 API response < 300ms under 2× normal load" |
| "Must be recoverable" | "RTO ≤ 60 min, RPO ≤ 24h; restore rehearsed quarterly" |
| "Must be secure" | "All external endpoints TLS 1.2+; named-user auth; leaver access revoked ≤ 15 min" |
| "Must scale" | "Support 2× workload growth without re-architecture; headroom ≥ 30% CPU on workers" |

Categories checklist — review every one at discovery, mark N/A explicitly rather than skip silently:

```
Availability  Performance  Scalability  Security  Compliance
Recoverability (RTO/RPO)  Observability  Maintainability  Portability  Usability
```

### NFR governance

- **Quantify at Day-0**, get sign-off — an unquantified NFR becomes a dispute at Day-1 acceptance
- **Every NFR maps to a test** — collect them into the acceptance criteria
- **Prioritize** — NFRs conflict (security vs convenience, HA vs cost); the customer picks the winner, you record it in an ADR

---

## Part 2 — Architecture Decision Records (ADRs)

### What they are

A lightweight document — one page — capturing a single architectural decision:

```
Context        What forced the decision (constraints, NFRs, deadlines)
Options        What was considered, with honest pros/cons
Decision       What was chosen and why
Consequences   What you gained AND what you accepted as cost
Status         Proposed → Accepted → Deprecated / Superseded by ADR-NNN
```

### Why they exist

| Problem without ADRs | What ADRs fix |
|---|---|
| "Why did we do it this way?" — 6 months later, nobody remembers | The decision + reasoning is a searchable artifact |
| Same debate relitigated every quarter | An ADR is revisited only via a *new* ADR superseding it |
| New team member reverse-engineers intent from configs | Reads the ADR index in an afternoon |
| Post-incident: "who decided this and why?" | Context section names the constraints and deciders |

### When to write one

- The decision is **hard to reverse** (topology, IdP choice, storage backend, CA strategy)
- It's **contested** — credible people disagreed
- It **trades off NFRs** (cost vs availability)
- Someone will plausibly ask "why?" later

Skip ADRs for: trivial choices, easily-reversed settings, anything fully dictated by a standard.

### Worked example — from this repo's real decisions

```markdown
# ADR-003: MetalLB L2 mode for bare-metal service exposure

Status: Accepted | Date: 2026-09-23 | Context: Issue 28

## Context
NFR: non-HTTP services (Postgres, JNLP agents) need stable external IPs on the
flat lab network 192.168.29.0/24. No BGP-capable ToR exists.

## Options
A. L2 mode (ARP)        — zero dependencies; VIP failover = seconds; one node answers
B. BGP mode             — ECMP, true per-node balancing; needs BGP-capable router
C. NodePort + external LB — extra hop; per-port management on the edge LB

## Decision
Option A — L2. Pool 192.168.29.70-90, L2Advertisement cluster-wide.

## Consequences
+ No network-team dependency, works today
+ VIP survives node loss (failover to another node)
- Failover drops concurrent TCP connections (gratuitous ARP move)
- Not ECMP — one node's NIC carries each VIP at a time

## Reversal cost
Low-medium: switching to BGP later = new Advertisement + ToR peering; service
IPs can be kept if the pool range is preserved.
```

### ADR lifecycle rules

- **Never edit history** — a wrong ADR is *superseded*, not deleted (the record of being wrong is valuable)
- **One decision per record** — a 10-decision "ADR" is an HLD
- **Consequences must include negatives** — an ADR with no accepted costs is marketing, not engineering
- **Index them** — keep a numbered list; reference ADRs from manifests/comments where the decision manifests

### NFR ↔ ADR relationship

```
NFR (what must be true)          ADR (what you chose and why)
─────────────────────            ─────────────────────────────
"RTO ≤ 1h"               ───►    ADR: cluster-restore.sh runbook + off-box snapshots
"99.9% availability"     ───►    ADR: 3-master topology; router HA on both workers
"TLS on all externals"   ───►    ADR: edge termination + cert-manager rotation
"Leaver access < 15 min" ───►    ADR: AD group sync hourly + no local accounts
```

The NFR is the *input*; the ADR records the *decision*; the manifest is the *output*. Keep all three.

---

## Using them together — the Day-0 flow

1. Discovery produces quantified NFRs (`templates/discovery-questionnaire.md`)
2. Each architecture decision cites its driving NFRs in the ADR Context
3. NFRs with no design answer = gaps → risk register
4. At acceptance: every NFR has a test, every major choice has an ADR
5. Day-2: incident RCAs that change architecture get *new* ADRs superseding the old

---

## Part 3 — The wider architecture & design vocabulary

NFRs and ADRs don't live alone — this is the rest of the vocabulary, grouped by where it sits in the lifecycle.

### Requirements & scoping (Day-0 inputs)

| Term | What it is |
|---|---|
| **FR** | Functional requirement — *what* the system does (pairs with NFR) |
| **Constraint** | Non-negotiable limit — budget, deadline, "must use existing F5", air-gap |
| **Assumption** | Treated as true but unverified — sits on the RAID log until confirmed |
| **MoSCoW** | Prioritization: Must / Should / Could / Won't — stops everything being "critical" |
| **SLA / SLO / SLI** | Contractual target / internal objective / measured indicator — e.g. SLI = measured uptime, SLO = 99.9% goal, SLA = contract with penalties |
| **RTO / RPO / MTTR** | How fast you must be back / tolerable data loss / average repair time — the DR trio |
| **Acceptance criteria** | Objective pass/fail tests defining "done" |
| **UAT** | User Acceptance Testing — the customer validates, not you |

### Architecture artifacts (Day-0 outputs)

| Term | What it is |
|---|---|
| **HLD** | High-Level Design — components, decisions, rationale; for approvers |
| **LLD** | Low-Level Design — object/manifest-level detail engineers execute (Issue 15 is one) |
| **C4 model** | Diagram standard: Context → Container → Component → Code zoom levels |
| **Reference architecture** | Vendor/community blessed pattern you adapt rather than invent |
| **DFD** | Data Flow Diagram — required input for threat modeling |
| **Architecture principles** | Standing rules: "everything via GitOps", "no secrets in git" |

### Decision & governance

| Term | What it is |
|---|---|
| **ADR** | Decision record — Part 2 |
| **RAID log** | Risks, Assumptions, Issues, Dependencies — the living engagement tracker (the risk register is just the R) |
| **RACI** | Responsible / Accountable / Consulted / Informed — one A per row |
| **Options paper / trade-off analysis** | Comparison doc feeding an ADR (like the MetalLB L2-vs-BGP example) |
| **ARB** | Architecture Review Board — enterprise governance gate for designs |
| **Technical debt register** | Deliberate shortcuts logged with a paydown plan |
| **Fitness functions** | Automated tests that enforce architecture rules ("no service without readinessProbe") |

### Delivery process terms

| Term | What it is |
|---|---|
| **PoC / Pilot / Spike** | Prove feasibility / limited prod rollout / time-boxed research task |
| **MVP** | Minimum Viable Product — smallest valuable first release |
| **Gate / exit criteria** | Checklist that must pass before the next phase (see `checklists/`) |
| **Cutover** | Planned switch old → new, with a defined rollback trigger |
| **Change management / CAB** | Approval workflow for production changes |
| **KT** | Knowledge transfer — the handoff activity |
| **Shift-left** | Moving testing/security earlier in the lifecycle |

### Quality vocabulary & distributed-systems terms

The "-ilities": **availability, reliability, scalability, elasticity, observability, maintainability, portability, interoperability, testability, deployability, auditability**.

Plus the terms that surface in every platform design conversation:

| Term | One-liner |
|---|---|
| **CAP theorem** | Under network partition, choose Consistency or Availability — not both |
| **Idempotency** | Repeating an operation gives the same result — required for safe retries |
| **Statelessness** | No local state → any replica serves any request → horizontal scale |
| **Immutability** | Replace, don't mutate — the image/container model |
| **HA vs FT vs DR** | HA = survives component failure; FT = survives without interruption; DR = recovers from site loss. Three different budgets — don't conflate |
| **Blast radius** | Worst-case scope of a failure/change — design to shrink it |

### The short list to memorize for OCP engagements

`SLA/SLO/SLI` · `RTO/RPO` · `RACI` · `RAID` · `HLD/LLD` · `gate/exit criteria` · `Day-0/1/2` — these come up in every customer conversation.
