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
