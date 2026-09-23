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
