# DR Execution — Team Responsibilities (RACI)

Who does what during a disaster-recovery failover. The central rule: **failing over is a business decision executed by the platform team** — the incident commander declares; engineers execute; nobody improvises parallel changes.

> One **A**ccountable per row. Adapt names/teams to your org.

## RACI matrix

| # | Activity | Incident Cmdr | Platform/OCP | Network/ADC | DBA | App/Dev | Backup Admin | Comms/PM |
|---|---|---|---|---|---|---|---|---|
| 1 | Declare disaster / trigger failover | **A** | C | C | C | C | I | R |
| 2 | Confirm DR cluster healthy (nodes, etcd, operators) | I | **A**/R | I | I | I | I | I |
| 3 | Verify data freshness at DR (replication lag, WAL/GTID position) | I | C | I | **A**/R | C | I | I |
| 4 | Promote DB replicas → primary | I | C | I | **A**/R | C | I | I |
| 5 | Restore workloads (Velero/manifests) | I | **A**/R | I | I | C | C | I |
| 6 | Storage/data-plane readiness (PVs, NFS/objects at DR) | I | **A**/R | C | I | I | C | I |
| 7 | DNS / GSLB / VIP traffic switch | I | C | **A**/R | I | I | I | I |
| 8 | Firewall/ACL/LB rule changes at DR site | I | C | **A**/R | I | I | I | I |
| 9 | Application smoke tests / functional validation | I | C | I | C | **A**/R | I | I |
| 10 | Stakeholder & status communications | I | I | I | I | I | I | **A**/R |
| 11 | Vendor escalations (storage, backup, LB) | C | R | R | C | I | R | I |
| 12 | **Failback decision** | **A** | C | C | C | C | I | R |

*R = does the work, A = owns the outcome, C = consulted, I = informed.*

## Execution sequence — order matters

```
1. DECLARE        Incident Cmdr + business owner → failover is GO
2. PLATFORM UP    DR cluster healthy: nodes Ready, etcd quorum, operators Available
3. DATA VERIFIED  DBA confirms replication caught up BEFORE promotion
4. DB PROMOTED    replicas → primary; connection strings/endpoints flipped
5. WORKLOADS      Velero restores / GitOps syncs bring apps up at DR
6. APPS VALIDATED app teams smoke-test before traffic
7. TRAFFIC        network team flips DNS/GSLB — LAST, not first
8. COMMS          status updates throughout; failback is a separate planned event
```

## Failure modes this prevents

| Failure | Guardrail |
|---|---|
| Failover never declared | Explicit GO decision owned by Incident Cmdr — drills rehearse the *declaration*, not just the tech |
| Parallel hands → split-brain (both sites live, writes diverge) | One runbook executor; Site A is fenced/powered-down or read-only before Site B takes traffic |
| DB promoted while replication lagged | Step 3 gate — DBA signs off on data position before step 4 |
| Traffic switched to an empty site | Traffic is step 7 — after platform, data, and app validation |
| No failback plan | Failback is a separate rehearsed event; DR runbook includes return-to-normal steps |

## Lab note

Single-site today — this matrix is the design target. In the lab, all platform/DBA/backup roles collapse to the same person, but keep the **sequence** (declare → platform → data → apps → traffic) — order is what prevents split-brain, not headcount.
