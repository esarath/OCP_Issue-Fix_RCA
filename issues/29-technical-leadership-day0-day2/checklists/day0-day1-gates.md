# Day-0 → Day-1 Gate Checklists

## Day-0 exit gate — "design approved to build"

- [ ] Discovery questionnaire complete; no blank must-have fields
- [ ] HLD approved in writing by customer decision-maker
- [ ] LLD exists for every build component (or build stories decomposed)
- [ ] ADRs for every consequential choice
- [ ] NFRs quantified: availability %, RTO/RPO, capacity headroom
- [ ] Risk register created, owned, reviewed with customer
- [ ] Build prerequisites confirmed available: DNS, VIPs, subnets, storage, creds, images/registry access
- [ ] Rollback strategy documented for Day-1 plan
- [ ] Acceptance criteria written — objective tests, not vibes
- [ ] Team: who builds, who reviews, customer pairing plan agreed

## Day-1 gate — "ready for production/cutover"

- [ ] All components deployed via repeatable automation/manifests (repo-committed, not CLI history)
- [ ] Smoke checks pass per stage (control plane → infra → workload)
- [ ] Monitoring + alerting live and routed to the right team
- [ ] Backup job ran at least once; restore rehearsed at least once
- [ ] Security baseline applied: IdP wired, RBAC groups bound, certs issued
- [ ] Load test vs acceptance criteria passed (or documented variance)
- [ ] Cutover runbook: freeze window, steps, timings, rollback trigger, comms bridge
- [ ] As-built docs updated — design matches reality
- [ ] Known issues logged with owner + workaround
