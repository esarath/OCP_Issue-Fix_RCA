# OCP Issue Fix & RCA Repository

**Cluster**: lab.ocp.local | OCP 4.20.35 | Proxmox (3 masters + 2 workers)

This repository is a living record of issues encountered on the OCP lab cluster.
Each issue has its own folder containing the RCA, fix steps, and any scripts used.

**Reading commands in this repo**: anything wrapped in angle brackets —
`<new-username>`, `<generated-password>`, `<target-namespace>`, `<date>`,
etc. — is a **placeholder**, not literal text. Replace the *entire* token,
including the `<` and `>` characters, with your actual value before running
the command. Typing a placeholder literally will either fail outright or,
worse, silently create a resource named e.g. `<new-username>`. This applies
throughout every `issues/` and `checklists/` document.

---

## Issue Index

| # | Title | Date | Severity | Status |
|---|---|---|---|---|
| [01](issues/01-web-console-unreachable/) | Web Console Unreachable After Cluster Restart | 2026-06-30 | High | Resolved |
| [02](issues/02-minor-version-upgrade-4.15-to-4.16/) | Minor Version Upgrade 4.15.59 → 4.16.55 | 2026-06-30 | Medium | Completed |
| [03](issues/03-ovn-kubernetes-crash-loop-after-reboot/) | OVN-Kubernetes Crash Loop on Rebooted Nodes (Web Console Down) | 2026-07-01 | High | Resolved |
| [04](issues/04-oc-client-server-version-skew/) | `oc` Client/Server Version Skew After Cluster Upgrade | 2026-07-01 | Low | Resolved |
| [05](issues/05-mtv-vm-migration-readiness/) | MTV VM Migration Readiness (ESXi/vCenter → OpenShift Virtualization) | 2026-07-01 | N/A (Planned Migration) | Precheck complete — Blocked on capacity |
| [06](issues/06-master-2-transient-notready-after-reboot/) | `master-2` Transient NotReady / `<unknown>` Metrics After Node Reboot | 2026-07-20 | Low | Resolved (self-healed) |
| [07](issues/07-recurring-cert-expiry-cron-blindspot/) | Recurring Kubelet Cert Expiry After Extended Shutdown; Cron Automation Blind Spot Found & Fixed | 2026-08-04 | Medium | Resolved |
| [08](issues/08-upgrade-4.19.41-to-4.19.42-and-channel-drift/) | Upgrade 4.19.41 → 4.19.42: Worker Image Pull Stall (IPv6 DNS) + Post-Upgrade Channel Drift | 2026-08-20 | Low / Medium | Resolved |
| [09](issues/09-upgrade-4.18-to-4.19-image-pull-timeout/) | Upgrade 4.18.50 → 4.19.41: Master Node Stuck on Extensions Image Pull | 2026-08-18 | Medium | Resolved (self-recovered) |
| [10](issues/10-onboard-babus-cluster-admin/) | Onboard `babus` as Named Cluster-Admin (Patching & Upgrade Duties) | 2026-08-20 | N/A (Administration) | Completed |
| [11](issues/11-4.19.43-patch-readiness-review/) | Cluster Patch Readiness Review: 4.19.42 → 4.19.43 Security Z-Stream | 2026-08-20 | N/A (Change Readiness Review) | Review complete — Blocked on target availability |
| [12](issues/12-uninstall-idle-cnv-reclaim-resources/) | Uninstall Idle OpenShift Virtualization (CNV) to Reclaim Resources | 2026-08-20 | N/A (Resource Reclamation) | Completed |
| [13](issues/13-420-upgrade-readiness-ram-remediation-and-prechecks/) | 4.20 Upgrade Readiness: Master RAM Remediation & Pre-Flight Validation | 2026-08-26 / 2026-08-27 | N/A (Change Readiness Review) | Superseded by issue 14 — readiness work led directly into the executed upgrade |
| [14](issues/14-419-to-420-upgrade-execution/) | 4.19.43 → 4.20.35 Minor Version Upgrade: Execution & Internals Deep-Dive | 2026-08-27 | N/A (Change Execution) | Completed — 1h29m, all 34 operators clean, etcd 3/3, 0 pending CSRs |
| [15](issues/15-redis-app-db-gitops-deployment/) | Redis (App + DB Tier) Deployment via OpenShift GitOps — LLD | 2026-08-28 | N/A (Planned Deployment) | LLD drafted and reviewed (v2) — not yet implemented on cluster |
| [16](issues/16-monitoring-alerting-validation-slack-critical-receiver/) | Monitoring/Alerting Deep-Dive Validation + Slack Receiver for Critical Alerts | 2026-08-29 | N/A (Change Execution) | Completed — stack validated healthy, `Critical` route wired to Slack (delivery confirmed), Alertmanager now PVC-backed |
| [17](issues/17-skopeo-local-registry-cluster-trust/) | Local Skopeo Registry on `svc-infra` + Cluster Trust/Pull Wiring | 2026-09-05 / 2026-09-06 | N/A (Change Execution) | Completed — registry live (TLS+auth, Quadlet-managed), cluster CA-trusts it, both MCPs rolled clean, real pod pull verified |
| [18](issues/18-urlshortener-fullstack-deploy-and-connect-services/) | Full-Stack JavaScript URL Shortener: Build, Deploy & Connect All Services | 2026-09-09 / 2026-09-10 | Medium | Resolved — app verified end-to-end; one cosmetic `/about` status-widget item open |
| [19](issues/19-jenkins-cicd-multibranch-pipeline/) | Jenkins CI/CD on `lab.ocp.local`: BuildConfig Pipeline + Multibranch + Stuck Cron RCA | 2026-09-13 | Medium | Completed — pipeline + multibranch + parallel tests verified end-to-end; one real incident (stuck Jenkins cron thread) root-caused and fixed |
| [20](issues/20-jenkins-to-github-actions-migration/) | Migrate `jenkins-sample-app` CI/CD from Jenkins to GitHub Actions | 2026-09-14 / 2026-09-15 | Medium | Completed — self-hosted runner live, pipeline verified end-to-end on the cluster; one blocking incident (bad YAML plain-scalar) root-caused and fixed |
| [21](issues/21-security-patch-application-guide-4.20.35/) | Security Patch Application Guide for OpenShift 4.20.35 | 2026-09-17 | N/A (Procedure/Documentation) | Procedure documented and ready for execution — comprehensive security patch guide for 4.20.35 → 4.20.38 |
| [22](issues/22-monitoring-scaling-approaches-memory-pressure-fix/) | Monitoring Scaling Approaches: Memory Pressure Fix Analysis | 2026-09-17 | Medium | Completed — CR patch approach successfully implemented to scale down monitoring replicas from 2 to 1 |
| [23](issues/23-pv-pvc-released-state-cleanup-approaches/) | PV/PVC Released-State Cleanup: All Approaches & Storage Claim Scenarios | 2026-09-17 | Low | Completed — 12 Released PVs (54Gi) deleted, 6 Bound remain; NFS server-side dir cleanup is the remaining manual step |
| [24](issues/24-stale-kubelet-ca-bundle-monitoring-blind-spot/) | Node Metrics Lost on worker-1: Stale Kubelet CA Bundle While CMO Is Unmanaged | 2026-09-21 | Low → Medium on 2026-09-25 | DRAFT — RCA complete, pending approval; re-enable CMO + clear ClusterVersion override recommended; blocks 4.20.38 patch |
| [25](issues/25-tls-cert-config-autorotation-any-app/) | TLS Certificate Configuration & Auto-Rotation for Routes (Any App/DB) | 2026-09-23 | N/A (Procedure/Documentation) | Documented — lab CA + edge route cert; auto-rotation via cert-manager/openshift-routes or cron script; DB passthrough/service-CA patterns included |
| [26](issues/26-ldap-ad-integration-centralized-auth/) | LDAP/Active Directory Integration: Centralized Auth & User/Group Management | 2026-09-23 | N/A (Procedure/Documentation) | Documented — LDAPS IdP on oauth/cluster, scheduled AD group sync CronJob, group-based RBAC, kubeadmin retirement; ready for execution |
| [27](issues/27-etcd-backup-restore-crash-recovery/) | etcd Backup, Restore & Control-Plane Crash Recovery | 2026-09-23 | N/A (DR Runbook) | Documented — cluster-backup.sh snapshots + automation, member-rebuild and full cluster-restore.sh recovery paths, validation checklist; ready for execution |
| [28](issues/28-load-balancer-planning-design/) | Load Balancer Planning & Design: Pod Traffic Distribution + External Exposure | 2026-09-23 | N/A (Architecture/Design) | Documented — 4-layer LB model (Service, Router/ingress, svc-infra HAProxy edge, MetalLB L4); probe-aligned health checks, source-IP and HA design, F5 CIS integration appendix; ready for review |
| [29](issues/29-technical-leadership-day0-day2/) | Technical Leadership Playbook: High-Value Complex Engagements Day-0 → Day-2 | 2026-09-23 | N/A (Framework/Methodology) | Documented — lifecycle gates, NFR/ADR deep-dive, discovery/ADR/risk templates, Day-2 handoff checklist; reusable across engagements |

---

## Repository Structure

```
OCP_Issue-Fix_RCA/
├── README.md                            # This file — issue index
│
├── issues/                              # One folder per issue
│   └── 01-web-console-unreachable/
│       ├── README.md                    # Issue summary & quick fix
│       ├── RCA.md                       # Full root cause analysis
│       └── scripts/
│           └── approve-csrs.sh         # Automated recovery script
│
├── checklists/                          # Operational checklists
│   ├── cluster-startup.md              # Run on every cluster restart
│   ├── admin-user-onboarding.md        # Add a traceable named cluster-admin user
│   ├── z-stream-patch-procedure.md     # Z-stream patch upgrade: pre/post checks, downtime, backup/restore plan
│   └── minor-version-upgrade-procedure.md  # Y-stream (minor) upgrade: pre/post checks, downtime, backup/restore plan
│
└── scripts/                             # Shared/reusable scripts
    └── approve-csrs.sh                 # (symlink to latest version)
```

---

## Cluster Reference

| Resource | Value |
|---|---|
| OCP Version | 4.20.35 |
| Console | `https://console-openshift-console.apps.lab.ocp.local` |
| API | `https://api.lab.ocp.local:6443` |
| HAProxy (Load Balancer) | `svc-infra.ocp.local` — 192.168.29.10 |
| Masters | 192.168.29.21 / .22 / .23 |
| Workers | 192.168.29.31 / .32 |
| SSH Key | `~/.ssh/ocp4-key` (user: `core`) |
| kubeconfig | `/home/centos/ocp/install/auth/kubeconfig` |

---

## How to Add a New Issue

1. Create a folder: `issues/NN-short-description/`
2. Add `README.md` (summary + quick fix)
3. Add `RCA.md` (full root cause analysis)
4. Add `scripts/` (any fix scripts used)
5. Add a row to the Issue Index table above
