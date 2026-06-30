# OCP Issue Fix & RCA Repository

**Cluster**: lab.ocp.local | OCP 4.15.59 | Proxmox (3 masters + 2 workers)

This repository is a living record of issues encountered on the OCP lab cluster.
Each issue has its own folder containing the RCA, fix steps, and any scripts used.

---

## Issue Index

| # | Title | Date | Severity | Status |
|---|---|---|---|---|
| [01](issues/01-web-console-unreachable/) | Web Console Unreachable After Cluster Restart | 2026-06-30 | High | Resolved |

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
│   └── cluster-startup.md              # Run on every cluster restart
│
└── scripts/                             # Shared/reusable scripts
    └── approve-csrs.sh                 # (symlink to latest version)
```

---

## Cluster Reference

| Resource | Value |
|---|---|
| OCP Version | 4.15.59 |
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
