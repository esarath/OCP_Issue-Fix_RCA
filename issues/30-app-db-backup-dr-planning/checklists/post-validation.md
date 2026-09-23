# Post-Validation Checklist — Backup/Restore & DR Implementation

Run AFTER deployment, and re-run on every change (new namespace onboarded, DPA changed, new region added). Items marked ★ are hard gates — the capability does not exist until they pass.

> Placeholders in `<angle brackets>` — replace before running.

---

## A. Backup execution validated

- [ ] ★ Every `Schedule` produced at least one `Completed` backup:
  `oc get backup -n openshift-adp` → no `PartiallyFailed`/`Failed`/`FailedValidation`
- [ ] Backup contents verified — objects AND volumes:
  `velero backup describe <name> --details` (or `oc get backup <name> -o yaml`) shows `progress.itemsBackedUp` > 0 and volume backups present
- [ ] Backup size is sane vs source data (a 50 MB backup of a 10 Gi PVC = wrong)
- [ ] Schedules fire at the expected off-peak times: `oc get schedule -n openshift-adp` + check `status.lastBackup`
- [ ] TTL/retention works — expired backups pruned: `oc get backup` list shrinks per policy
- [ ] `scripts/velero-backup-check.sh` exits 0

## B. Restore validated — the gate that matters

- [ ] ★ **Drill restore executed**: a real backup restored to a mapped copy namespace (`namespaceMapping`), phase `Completed`
- [ ] ★ Restored app actually functions: pods Ready, route/endpoint answers, app-level smoke test passes — not just "objects exist"
- [ ] ★ Restored PV data verified: files present, row counts/spot queries on DB dumps match expectations
- [ ] Restore duration measured → compared against the RTO target; variance documented
- [ ] Drill result recorded (date, backup used, issues found) in this repo
- [ ] Drill namespace cleaned up: `oc delete project <ns>-drill`

## C. Database restore validated

- [ ] ★ Logical dump restored into a test instance: `pg_restore`/`psql < dump` (or mysql equivalent) completes without error
- [ ] Spot-check data integrity: row counts on key tables, app-level read test
- [ ] Velero pre/post hook fired correctly during a backup (pod logs / backup describe shows hooks ran)
- [ ] Dump PVC is inside a Velero-backed-up namespace

## D. Monitoring & alerting validated

- [ ] `BackupStorageLocation` Unavailable produces an alert (test: temporarily break creds in a non-prod window, or verify the alert rule exists)
- [ ] Failed `Backup`/`Schedule` objects surface in monitoring
- [ ] Backup job failures go to the team's alert channel (Slack per Issue 16), not a log nobody reads
- [ ] Dashboard/report shows last-successful-backup age per schedule

## E. DR readiness validated (if second region in scope)

- [ ] ★ Backup bucket confirmed replicated/reachable **from the DR site** — not just "replication enabled"
- [ ] DR cluster can pull images (pull-secret/registry trust verified)
- [ ] A restore onto the DR cluster has been executed at least once (namespaceMapping drill)
- [ ] DNS/failover procedure rehearsed — documented timing vs RTO
- [ ] Route/cert strategy verified: routes resolve at DR domain, certs issued (cert-manager auto-issues per Issue 25)
- [ ] Failover runbook executed end-to-end by the person who'll actually run it at 3 AM

## F. Operational readiness

- [ ] Runbook written: how to restore a namespace / a PV / a DB — customer-executable
- [ ] Restore-drill calendar entry created (monthly) with an owner
- [ ] Backup credentials rotation plan documented (they expire — who owns renewal?)
- [ ] Storage quota alert on the backup bucket
- [ ] Open exceptions logged in the risk register with named owner

---

## Sign-off

| Check | Result | Date | By |
|---|---|---|---|
| Backups completing on schedule | ☐ Pass | | |
| Restore drill passed | ☐ Pass | | |
| DB restore verified | ☐ Pass | | |
| Alerts fire | ☐ Pass | | |
| DR failover rehearsed (if applicable) | ☐ Pass / N/A | | |
| **Backup/DR capability: ACCEPTED** | ☐ | | |
