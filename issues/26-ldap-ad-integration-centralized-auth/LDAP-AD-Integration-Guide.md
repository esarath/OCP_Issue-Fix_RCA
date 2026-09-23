# LDAP / Active Directory Integration with OpenShift — Centralized Authentication & User/Group Management

Complete step-by-step guide to wire the OCP cluster to Active Directory (or any LDAP) so that authentication, group membership, and permissions are managed centrally in AD — not in cluster-local accounts.

> **Placeholder convention** (repo-wide): anything in `<angle brackets>` is a placeholder — replace the whole token before running.

---

## Table of Contents

1. [How OCP authentication works — the mental model](#part-0--how-ocp-authentication-works)
2. [Prerequisites — what to collect from the AD admin](#part-1--prerequisites)
3. [Create the bind secret and CA ConfigMap](#part-2--create-the-bind-secret-and-ca-configmap)
4. [Configure the LDAP identity provider](#part-3--configure-the-ldap-identity-provider)
5. [Verify first login](#part-4--verify-first-login)
6. [AD group sync — automated](#part-5--ad-group-sync--automated)
7. [Map AD groups to OCP roles (RBAC)](#part-6--map-ad-groups-to-ocp-roles-rbac)
8. [Day-2 operations — joiner/leaver, kubeadmin retirement](#part-7--day-2-operations)
9. [OpenLDAP (non-AD) differences](#part-8--openldap-non-ad-differences)
10. [Troubleshooting](#part-9--troubleshooting)
11. [Rollback](#part-10--rollback)

---

## Part 0 — How OCP authentication works

Three objects are involved, and understanding them prevents 90% of confusion:

```
Login attempt
     │
     ▼
OAuth server (openshift-authentication)  ──►  queries configured IdentityProviders in order
     │                                            (ldap, htpasswd, etc.)
     │  on success
     ▼
Identity object   — "this AD account authenticated" (one per IdP:user pair)
     │  mappingMethod: claim
     ▼
User object       — the OCP principal that RBAC binds to (auto-created on first login)
     │
     ▼
Group objects     — populated ONLY by group sync (AD groups are NOT automatic)
```

**Critical detail:** configuring the LDAP IdP gives you *authentication only*. A user can log in but belongs to **no groups** and has **no permissions** until either (a) group sync runs and (b) RBAC is bound to the synced groups. Authentication ≠ authorization — both halves are in this guide.

`mappingMethod` options:

| Value | Behavior | When |
|---|---|---|
| `claim` *(recommended)* | First login auto-creates a `User` and links the `Identity` | Normal case — zero-touch provisioning |
| `lookup` | Admin pre-creates `User`/`Identity`; login only allowed if they exist | Strict allowlist environments |
| `add` | Like claim, but errors if the username already exists under another IdP | Avoids accidental account-merge |
| `generate` | Auto-generates a unique username on collision | Multiple IdPs with overlapping usernames |

---

## Part 1 — Prerequisites

Collect these **before** touching the cluster. Half the failures in LDAP integrations are missing one of these.

| Item | Example value | Get it from |
|---|---|---|
| AD hostname(s), LDAPS port | `<ad-host>:636` | AD admin / DNS |
| Base DN | `DC=lab,DC=ocp,DC=local` | `dsquery`, AD admin |
| Users container DN | `CN=Users,DC=lab,DC=ocp,DC=local` (or an OU like `OU=People,...`) | AD admin |
| Bind service account DN + password | `CN=svc-ocp-ldap,CN=Users,...` | AD admin — **dedicated read-only account**, password set to never-expire or rotation plan |
| AD CA / LDAPS cert chain | `ad-ca.crt` | `scripts/get-ad-ca.sh <ad-host>` or the PKI admin |
| AD groups to map | `OCP-Cluster-Admins`, `OCP-Operators`, `OCP-Developers` | **Create these in AD first** — sync can't invent groups |
| Cluster reachability | TCP/636 open from masters → AD | `nc -zv <ad-host> 636` from a node |

### 1.1 Create the AD service account

Ask AD admin for (or create via PowerShell on a DC):

```powershell
New-ADUser -Name "svc-ocp-ldap" -SamAccountName "svc-ocp-ldap" `
  -UserPrincipalName "svc-ocp-ldap@lab.ocp.local" `
  -AccountPassword (Read-Host -AsSecureString "Password") `
  -Enabled $true -PasswordNeverExpires $true -CannotChangePassword $true
# No special rights needed — a normal domain user can read the directory
```

### 1.2 Create the AD groups

```powershell
New-ADGroup -Name "OCP-Cluster-Admins" -GroupScope Global -Path "CN=Users,DC=lab,DC=ocp,DC=local"
New-ADGroup -Name "OCP-Operators"      -GroupScope Global -Path "CN=Users,DC=lab,DC=ocp,DC=local"
New-ADGroup -Name "OCP-Developers"     -GroupScope Global -Path "CN=Users,DC=lab,DC=ocp,DC=local"
```

### 1.3 Verify LDAPS from the cluster network

```bash
# From any node or your admin host with cluster-equivalent network access
openssl s_client -connect <ad-host>:636 -servername <ad-host> </dev/null | head -20
./scripts/get-ad-ca.sh <ad-host>          # extracts the CA chain to ad-ca.crt
```

If this fails, fix DNS/firewall/cert **now** — the OAuth pods will hit the same wall.

---

## Part 2 — Create the bind secret and CA ConfigMap

Two objects in `openshift-config`, referenced by the OAuth config by name:

```bash
# The bind password — keyed as 'bindPassword' (exact key name required)
oc create secret generic ldap-secret \
  --from-literal=bindPassword='<service-account-password>' \
  -n openshift-config

# The AD CA chain — keyed as 'ca.crt' (exact key name required)
oc create configmap ldap-ca \
  --from-file=ca.crt=ad-ca.crt \
  -n openshift-config
```

> **Security**: never `insecure: true` outside a wireshark-debugging session — it sends AD bind credentials over cleartext LDAP. LDAPS on 636 (or StartTLS) with the CA in the ConfigMap is the baseline.

---

## Part 3 — Configure the LDAP identity provider

### 3.1 Check existing IdPs first (don't blow away break-glass auth)

```bash
oc get oauth cluster -o yaml | yq '.spec.identityProviders'
```

If an HTPasswd or other IdP exists, **keep it in the list** — the new LDAP entry is added alongside. `oc apply` merges the list; `oc replace`/edit-and-delete does not.

### 3.2 Apply the OAuth config

`manifests/oauth-ldap.yaml` — the load-bearing fields:

| Field | Why it matters |
|---|---|
| `url` | `ldaps://<host>:636/<basedn>?<uid-attr>?sub?<filter>` — the search that finds the user. `sAMAccountName` = AD logon name; filter `(objectClass=user)` excludes computers/groups |
| `attributes.id: [dn]` | The immutable key linking Identity↔AD account. `dn` survives renames; never use `sAMAccountName` here (renames orphan users) |
| `attributes.preferredUsername` | What the user types at `oc login` / sees in the console |
| `mappingMethod: claim` | Auto-provisions `User` on first login |
| `bindDN` / `bindPassword` | The read-only service account used for searches |
| `ca` | Trusts the LDAPS cert — required when `insecure: false` |

```bash
# Edit placeholders, then:
oc apply -f manifests/oauth-ldap.yaml

# OAuth server rolls out new pods (~1-2 min)
oc get pods -n openshift-authentication -w
```

**Multiple AD servers**: list them space-separated in the URL host portion — `url: "ldaps://<dc1>:636 <dc2>:636/CN=Users,DC=lab,..."` — OCP fails over between them.

### 3.3 What the console shows

After rollout, the console login page gains a `lab-ad` option on the identity picker (any existing providers remain). CLI logins just work with AD creds directly.

---

## Part 4 — Verify first login

```bash
# CLI — creates User + Identity on success
oc login -u '<ad-samaccountname>' -p '<ad-password>' --server=https://api.lab.ocp.local:6443
oc whoami                        # should print the sAMAccountName

# Inspect the objects that were auto-created
oc get users
oc get identities                # name = <idp-name>:<ldap-id-attr>
oc describe user <ad-samaccountname>
```

Expected shape:

```
IDENTITY                          NAME: lab-ad:CN=jdoe,CN=Users,DC=lab,DC=ocp,DC=local
USER                              jdoe   identities: [lab-ad:CN=jdoe,...]
```

The user can log in but sees `Forbidden` everywhere — correct: no groups/roles yet. That's Part 5+6.

---

## Part 5 — AD group sync — automated

Group sync pulls AD group membership into OCP `Group` objects so you can bind roles to **groups** instead of individual users.

### 5.1 Stage the config and secrets in the sync namespace

```bash
oc apply -f manifests/group-sync/sync-rbac.yaml      # ns + SA + ClusterRole + binding

oc create configmap ldap-sync-config \
  --from-file=sync.yaml=manifests/group-sync/ldap-sync-config.yaml -n ldap-group-sync
oc create configmap ldap-ca --from-file=ca.crt=ad-ca.crt -n ldap-group-sync
oc create secret generic ldap-bind-secret \
  --from-literal=bindPassword='<service-account-password>' -n ldap-group-sync
```

### 5.2 Dry-run the sync manually first — ALWAYS

```bash
# Run one job ad-hoc WITHOUT --confirm to see what it would do
oc create job --from=cronjob/ldap-group-sync ldap-sync-dryrun -n ldap-group-sync 2>/dev/null || \
oc -n ldap-group-sync run ldap-sync-dryrun --rm -i --restart=Never \
  --image=registry.redhat.io/openshift4/ose-cli:latest \
  --overrides='{"spec":{"serviceAccountName":"ldap-group-syncer","volumes":[...]}}' -- \
  oc adm groups sync --sync-config=/etc/ldap-sync/sync.yaml
```

Simplest dry-run: temporarily remove `--confirm` from the CronJob args, `oc create job --from=cronjob/...`, read the pod logs, then restore. The sync prints every group it would create/update and every membership delta.

### 5.3 Scope the sync (important for large directories)

Unfiltered sync creates an OCP Group for **every** AD group — thousands of junk groups. Use one of:

- **Whitelist** (explicit DN list — most predictable): uncomment `whitelist:` in `ldap-sync-config.yaml`
- **Naming convention** (recommended): AD groups prefixed `OCP-*`, then set the groupsQuery filter to `(&(objectClass=group)(cn=OCP-*))`
- **Blacklist**: exclude specific DNs

### 5.4 Schedule it

```bash
oc apply -f manifests/group-sync/sync-cronjob.yaml    # hourly at :15
oc get cronjob -n ldap-group-sync

# Trigger one now:
oc create job --from=cronjob/ldap-group-sync manual-sync-1 -n ldap-group-sync
oc logs -n ldap-group-sync job/manual-sync-1 -f

oc get groups                                       # AD groups appear
oc describe group OCP-Cluster-Admins                # members listed
```

> **Sync direction is one-way** — AD → OCP. Deleting a user from an AD group removes them from the OCP group on next sync. Manually-edited OCP group membership gets **overwritten** by sync; manage membership in AD only.

---

## Part 6 — Map AD groups to OCP roles (RBAC)

`manifests/ad-group-rolebindings.yaml` — the pattern:

| AD group | OCP binding | Scope | Result |
|---|---|---|---|
| `OCP-Cluster-Admins` | `cluster-admin` | ClusterRoleBinding | Full cluster control |
| `OCP-Operators` | `cluster-reader` | ClusterRoleBinding | See everything, change nothing |
| `OCP-Developers` | `edit` | RoleBinding per namespace | Deploy/manage in their projects only |

```bash
oc apply -f manifests/ad-group-rolebindings.yaml

# Verify effective access as an AD user
oc auth can-i '*' '*' --as=<ad-admin-user>                  # expect yes
oc auth can-i create deployment -n <dev-ns> --as=<dev-user> # expect yes
oc auth can-i '*' '*' --as=<dev-user>                       # expect no
```

Common built-in roles for the bindings: `cluster-admin`, `cluster-reader`, `admin` (per-ns), `edit`, `view`, `self-provisioner`. Full list: `oc get clusterrole | grep -v system:`.

---

## Part 7 — Day-2 operations

### 7.1 Joiner / leaver flow

| Event | What happens |
|---|---|
| New hire added to `OCP-Developers` in AD | Next sync puts them in the OCP group → they can log in with edit rights. No cluster action needed. |
| User leaves / disabled in AD | LDAP bind fails at next login attempt → locked out immediately. Their OCP group membership clears on next sync. |
| User moves teams (group change in AD) | Next sync adjusts OCP membership; permissions follow the new group. |

Stale `User`/`Identity` objects linger after leavers — cosmetic; clean periodically:

```bash
oc get users                                # cross-check against AD
oc delete user <user> && oc delete identity lab-ad:<user-dn>
```

### 7.2 Retire kubeadmin (do this LAST, after AD admin login verified)

```bash
# Verify an AD account has cluster-admin and can log in FIRST. Then:
oc delete secret kubeadmin -n kube-system
```

**Keep a break-glass path**: either leave an HTPasswd IdP with one strong local account, or document that IdP recovery requires `kubeconfig` from `~/ocp/install/auth/` (the installer-generated cert-based admin — independent of OAuth entirely). If OAuth breaks, that kubeconfig still works.

### 7.3 Rotating the bind password

```bash
oc create secret generic ldap-secret --from-literal=bindPassword='<new-pw>' \
  -n openshift-config --dry-run=client -o yaml | oc apply -f -
oc create secret generic ldap-bind-secret --from-literal=bindPassword='<new-pw>' \
  -n ldap-group-sync --dry-run=client -o yaml | oc apply -f -
# OAuth pods pick up the new secret on next auth attempt; sync picks it up next run
```

---

## Part 8 — OpenLDAP (non-AD) differences

Same structure; the attribute names change:

| Setting | Active Directory | OpenLDAP / RFC2307 |
|---|---|---|
| Login attribute | `sAMAccountName` | `uid` |
| Display name | `displayName` | `cn` |
| User filter | `(objectClass=user)` | `(objectClass=inetOrgPerson)` |
| Group membership | `memberOf` (overlay) + `1.2.840.113556.1.4.1941` matching rule for nesting | `member`/`memberUid` on the group |
| Sync schema | `augmentedActiveDirectory:` | `rfc2307:` (or `rfc2307bis:` for `member`-based groups) |

Swap the schema block in `ldap-sync-config.yaml`; everything else (OAuth shape, RBAC, CronJob) is identical.

---

## Part 9 — Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| Login page has no `lab-ad` option | OAuth pods didn't roll / config rejected | `oc get pods -n openshift-authentication`; `oc describe oauth cluster` |
| `x509: certificate signed by unknown authority` on login | Wrong/missing CA in `ldap-ca` ConfigMap | Re-run `get-ad-ca.sh`; ensure **root** CA, recreate ConfigMap |
| `LDAP Result Code 49 Invalid Credentials` | Bad bindDN or bind password | Test standalone: `ldapsearch -H ldaps://<ad-host>:636 -D '<bindDN>' -w '<pw>' -b '<basedn>'` |
| `LDAP Result Code 32 No Such Object` | baseDN in `url` wrong | Verify with `ldapsearch -b '<basedn>'` — OU vs CN=Users confusion is common |
| Login works, `Forbidden` everywhere | Groups not synced or no RBAC | `oc get groups`, run sync, check bindings |
| Groups sync creates hundreds of junk groups | No whitelist/filter | Part 5.3 — scope the query |
| `oc describe group` shows empty members | `userNameAttributes` mismatch with OAuth `preferredUsername` | Both must resolve to `sAMAccountName` |
| Username collision across IdPs | Same name in htpasswd + AD | `mappingMethod: add` or `generate`; or remove the stale identity |
| Console login loops | Clock skew / oauth pod restart mid-auth | `oc logs -n openshift-authentication deploy/oauth-openshift` |
| Sync job fails auth to API | SA/RBAC missing | `oc auth can-i update groups --as=system:serviceaccount:ldap-group-sync:ldap-group-syncer` |

Useful deep-debug:

```bash
oc logs -n openshift-authentication -l app=oauth-openshift --tail=100 | grep -i ldap
oc adm groups sync --sync-config=sync.yaml            # no --confirm = dry run
ldapsearch -x -H ldaps://<ad-host>:636 -D '<bindDN>' -w '<pw>' \
  -b 'CN=Users,DC=lab,DC=ocp,DC=local' '(sAMAccountName=<user>)' memberOf
```

---

## Part 10 — Rollback

```bash
# Remove just the LDAP IdP — keep other providers
oc get oauth cluster -o yaml > oauth-backup.yaml
oc edit oauth cluster          # delete the '- name: lab-ad' block, save

# If OAuth is fully broken, use the installer kubeconfig (bypasses OAuth):
export KUBECONFIG=~/ocp/install/auth/kubeconfig
oc edit oauth cluster          # fix or remove the bad IdP entry
```

Rollback impact: AD users lose login immediately; `User`/`Identity`/synced `Group` objects remain (harmless — delete them manually if desired).

---

## Summary architecture

```
AD (lab.ocp.local)
  │  LDAPS :636 — bind via svc-ocp-ldap (read-only)
  ▼
oauth/cluster  ──LDAP IdP──►  Identity + User auto-created on login
  │
CronJob ldap-group-sync (hourly) ──► OCP Groups mirror AD OCP-* groups (incl. nested)
  │
ClusterRoleBindings / RoleBindings on Groups ──► permissions
  │
kubeadmin deleted; installer kubeconfig = break-glass
```
