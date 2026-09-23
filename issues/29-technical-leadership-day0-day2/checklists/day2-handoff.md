# Day-2 Handoff Checklist — exit gate

Complete ALL before disengaging. Items marked ★ are non-negotiable.

## Capability transfer
- [ ] ★ Customer engineer executed each top-5 runbook themselves (observed):
      upgrade check, patch, backup, restore, cert renewal, common incident triage
- [ ] ★ A DR restore was performed by the customer — not just watched
- [ ] KT sessions recorded; links stored in repo
- [ ] Customer can add issues/RCAs following the repo convention

## Operational ownership
- [ ] ★ Alerts route to customer channels/on-call — verified by a fired alert
- [ ] Monitoring dashboards handed over; capacity thresholds explained
- [ ] Patch/upgrade cadence agreed and scheduled
- [ ] Cert expiry automation or calendar reminders in place
- [ ] Backup schedule + off-box copy + retention verified running

## Access & secrets
- [ ] ★ All credentials transferred to customer secret management
- [ ] Any consultant access formally revoked or time-boxed
- [ ] Break-glass path documented and tested (kubeconfig/kubeadmin-equivalent)

## Open items
- [ ] ★ Risk register: every open risk accepted by a named customer owner
- [ ] Open issues/bugs listed with severity + workaround + follow-up owner
- [ ] Roadmap recommendations captured (deferred nice-to-haves)

## Commercial/admin
- [ ] Acceptance sign-off received
- [ ] Final report delivered: as-built state, KPIs vs targets, lessons learned
