# Issue 26 — LDAP / Active Directory Integration: Centralized Auth & User/Group Management

| Field | Detail |
|---|---|
| **Date** | 2026-09-23 |
| **Type** | Procedure/Documentation — identity provider integration |
| **Status** | Documented — ready for manual execution |
| **Scope** | End-to-end: AD/LDAP identity provider on the cluster OAuth, group sync, group-based RBAC, kubeadmin retirement |
| **Cluster** | lab.ocp.local (OCP 4.20.35, dev/testing environment) |
| **Goal** | Users log in with AD credentials; AD groups drive OCP permissions; no per-user local accounts |
| **Approach** | `LDAP` identity provider (LDAPS) + scheduled `oc adm groups sync` CronJob + ClusterRoleBindings on synced groups |

---

## Why This Exists

Today the cluster authenticates via `kubeadmin` (and any ad-hoc HTPasswd users) — no central identity, no group-based RBAC, no joiner/leaver process. Integrating with AD gives:

- **Centralized authentication** — users log in to the console/API with their normal AD credentials
- **Centralized authorization** — AD group membership (e.g. `OCP-Cluster-Admins`, `OCP-Developers`) maps to OCP roles via group sync + ClusterRoleBindings; disable a user in AD → access dies on next login attempt
- **Auditability** — real named users in `oc get users` / audit logs instead of shared kubeadmin

## Quick Path

| Step | Where |
|---|---|
| Full walkthrough with explanations | [LDAP-AD-Integration-Guide.md](LDAP-AD-Integration-Guide.md) |
| Just the OAuth config | `manifests/oauth-ldap.yaml` |
| Group sync automation | `manifests/group-sync/` (CronJob + RBAC + sync config) |
| AD group → OCP role bindings | `manifests/ad-group-rolebindings.yaml` |

## TL;DR — the four objects

```bash
# 1. Bind-password secret + AD CA cert ConfigMap
oc create secret generic ldap-secret --from-literal=bindPassword='<bind-pw>' -n openshift-config
oc create configmap ldap-ca --from-file=ca.crt=ad-ca.crt -n openshift-config

# 2. Point cluster OAuth at AD
oc apply -f manifests/oauth-ldap.yaml          # edits oauth/cluster — triggers oauth pod rollout

# 3. Verify
oc login -u '<ad-user>' -p '<ad-pw>'           # creates User + Identity objects on first login

# 4. Sync AD groups on a schedule, then bind roles to them
oc apply -f manifests/group-sync/
oc apply -f manifests/ad-group-rolebindings.yaml
```

## Files

```
26-ldap-ad-integration-centralized-auth/
├── README.md                                # This file
├── LDAP-AD-Integration-Guide.md             # Full step-by-step guide
├── manifests/
│   ├── oauth-ldap.yaml                      # oauth/cluster — LDAP IdP (LDAPS)
│   ├── ldap-secret.yaml                     # bind-password secret (template)
│   ├── ad-group-rolebindings.yaml           # AD group -> cluster role bindings
│   └── group-sync/
│       ├── ldap-sync-config.yaml            # augmentedActiveDirectory sync config
│       ├── sync-rbac.yaml                   # SA + ClusterRole for the sync job
│       └── sync-cronjob.yaml                # scheduled group sync
└── scripts/
    └── get-ad-ca.sh                         # pull the AD LDAPS cert chain
```
