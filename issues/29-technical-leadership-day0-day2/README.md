# Issue 29 — Technical Leadership Playbook: High-Value Complex Engagements, Day-0 → Day-2

| Field | Detail |
|---|---|
| **Date** | 2026-09-23 |
| **Type** | Framework/Methodology — engagement leadership playbook |
| **Status** | Documented — reusable across engagements |
| **Scope** | Technical leadership practices across the full lifecycle: Day-0 architecture/design, Day-1 build/deploy, Day-2 operations/handoff |
| **Audience** | Lead architect / consulting engineer on complex OCP (or comparable platform) engagements |
| **Companion artifacts** | `templates/` — discovery questionnaire, ADR, risk register; `checklists/` — per-phase gate checklists |

---

## Why This Exists

Complex engagements fail on **process and communication gaps** far more often than on technical ones. This playbook is the repeatable framework: what the technical lead owns at each phase, which artifacts must exist before moving forward, and how to hand off so Day-2 doesn't become a support black hole.

## The lifecycle at a glance

```
Day-0  ARCHITECT     Discovery → requirements → HLD/LLD → ADRs → risk register → approval gate
Day-1  BUILD         Install/deploy → validate → test → cutover → acceptance gate
Day-2  OPERATE       Monitoring → patching → DR → certs/LB/auth ops → KT → handoff gate
```

This repo is itself a Day-2 artifact — every `issues/NN-*` entry is the RCA/runbook pattern the playbook prescribes (Issues 21–28 are the worked examples: patching, monitoring, PV cleanup, certs, auth, etcd DR, LB design).

## Quick Path

| Need | Go to |
|---|---|
| What a tech lead owns per phase | [Playbook](Technical-Leadership-Playbook.md) Part 2 |
| Day-0 discovery & architecture method | Playbook Part 3 + `templates/discovery-questionnaire.md` |
| Design artifacts & decision recording | Playbook Part 3.4 + `templates/architecture-decision-record.md` |
| Day-1 build/validate/cutover | Playbook Part 4 + `checklists/` |
| Day-2 ops model & handoff | Playbook Part 5 + `checklists/handoff.md` |
| Stakeholder/comms/risk practice | Playbook Part 6 + `templates/risk-register.md` |

## Files

```
29-technical-leadership-day0-day2/
├── README.md                                # This file
├── Technical-Leadership-Playbook.md         # Full methodology
├── templates/
│   ├── discovery-questionnaire.md           # Day-0 stakeholder/requirements capture
│   ├── architecture-decision-record.md      # ADR template
│   └── risk-register.md                     # Risk tracking template
└── checklists/
    ├── day0-day1-gates.md                   # Design-complete & go-live readiness gates
    └── day2-handoff.md                      # Operations handoff checklist
```
