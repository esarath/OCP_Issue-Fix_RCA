# Issue 10 — Onboard `babus` as Named Cluster-Admin (Patching & Upgrade Duties)

| Field | Detail |
|---|---|
| **Date** | 2026-08-20 |
| **Type** | Administration (access provisioning), not an incident |
| **Status** | Completed |
| **Purpose** | Add a second person able to manage cluster patching/upgrades, as an individually-traceable account — not a shared credential |
| **Procedure followed** | [checklists/admin-user-onboarding.md](../../checklists/admin-user-onboarding.md), steps 1–3 |

---

## Why

This cluster needed a second admin for day-to-day patching and upgrade work.
Following the traceability lesson from [issue 08](../08-upgrade-4.19.41-to-4.19.42-and-channel-drift/README.md)
(where a channel change couldn't be attributed to a person because it went
through the shared `kubeadmin` credential), the new account was created as a
**named** HTPasswd user with its own individual `ClusterRoleBinding`, so every
action `babus` takes going forward shows up as `babus` in the audit log — not
`kube:admin` or any other shared identity.

`kubeadmin` retirement and the `WriteRequestBodies` audit profile upgrade
(steps 4–5 of the checklist) were **not** performed as part of this — those
are separate, more disruptive changes to be done deliberately, not bundled
into a routine user-add.

> **Placeholder convention**: `<generated-password>` in the commands below is
> a placeholder standing in for the actual password value that was generated
> at the time — not literal text. The real password is never written into
> this repo (it was shared with the requester once, out-of-band, and is not
> reproduced here). If you're following this as a template for onboarding a
> *different* user, generate a fresh password and substitute it in place of
> the whole `<generated-password>` token, angle brackets included.

---

## Steps Executed

### Step 1 — Add `babus` to the HTPasswd identity provider

**Purpose**: the cluster's OAuth config (`oc get oauth cluster`) points at
exactly one identity provider — HTPasswd, backed by secret `htpasswd-secret`
in `openshift-config`. A new account only takes effect if it's added to
*that* file; anything else is inert.

```bash
oc extract secret/htpasswd-secret -n openshift-config --to=- --keys=htpasswd > users.htpasswd
htpasswd -Bb users.htpasswd babus '<generated-password>'
oc create secret generic htpasswd-secret --from-file=htpasswd=users.htpasswd \
  -n openshift-config --dry-run=client -o yaml | oc apply -f -
```

**Gotcha hit and fixed**: `oc extract ... --to=-` prepends a `# htpasswd`
comment header when writing to stdout. This is not part of the actual
htpasswd file — it was stripped (`tail -n +2`) before writing the secret
back. Left in place, it risks the HTPasswd identity provider parser
rejecting or mis-parsing the file. Worth remembering for next time this
extract pattern is used.

### Step 2 — Grant `cluster-admin` to `babus` specifically

**Purpose**: bind the `cluster-admin` ClusterRole to the named `User`
object, not a group or shared identity — this is the actual mechanism that
makes future actions traceable.

```bash
oc adm policy add-cluster-role-to-user cluster-admin babus
```
```
Warning: User 'babus' not found
clusterrole.rbac.authorization.k8s.io/cluster-admin added: "babus"
```
The warning is expected and harmless — OpenShift `User` objects are created
lazily on first successful login via the identity provider; the RBAC binding
can reference the username ahead of that first login.

Confirmed:
```
$ oc get clusterrolebindings ... | grep babus
cluster-admin-3 -> User babus
```

### Step 3 — Verify login and access, without disturbing the active admin session

**Purpose**: prove the account actually works end-to-end before considering
it done — and check `oc auth can-i` directly rather than trusting the
binding alone.

```bash
cp <existing-admin-kubeconfig> /tmp/babus-kubeconfig   # reuse trusted cluster CA
oc login -u babus -p '<generated-password>' https://api.lab.ocp.local:6443 \
  --kubeconfig=/tmp/babus-kubeconfig
oc whoami --kubeconfig=/tmp/babus-kubeconfig
oc auth can-i '*' '*' --all-namespaces --kubeconfig=/tmp/babus-kubeconfig
```
```
Login successful.
babus
yes
```

**Gotcha hit and fixed**: a fresh, from-scratch kubeconfig fails with
`certificate signed by unknown authority` against this cluster's custom CA.
Fixed by copying the existing trusted kubeconfig first and logging in against
that copy (which swaps only the user credentials, keeping the cluster/CA
entry) — rather than passing `--insecure-skip-tls-verify` or manually
sourcing the CA cert.

Confirmed `babus` User object now exists post-login:
```
$ oc get user babus
NAME    UID                                    FULL NAME   IDENTITIES
babus   3ed83251-7a30-45f9-ba41-4917a71131d1               htpasswd:babus
```

### Cleanup

Temporary files containing the plaintext password and the test kubeconfig
(which held a live token) were deleted immediately after verification — not
left on disk.

---

## Verification Summary

| Check | Result |
|---|---|
| `htpasswd-secret` contains `babus` entry | ✅ |
| `cluster-admin` ClusterRoleBinding exists for `babus` | ✅ (`cluster-admin-3`) |
| `babus` can log in | ✅ |
| `oc auth can-i '*' '*' --all-namespaces` as `babus` | ✅ `yes` |
| `User` object created | ✅ |
| Plaintext credentials cleaned up from disk | ✅ |

---

## Follow-ups

- Have `babus` rotate the initial generated password on first real use.
- Not yet done, still recommended per [issue 08](../08-upgrade-4.19.41-to-4.19.42-and-channel-drift/README.md):
  retire `kubeadmin` and raise the audit profile to `WriteRequestBodies`,
  once there are enough named admins that the shared bootstrap credential is
  no longer needed by anyone.
