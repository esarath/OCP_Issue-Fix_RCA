# Checklist — Adding a Named Cluster-Admin User (with Traceability)

**Use this when**: granting another person cluster-admin access, especially for
upgrade/administration duties, and you need every future change they make to
be attributable to them individually in the audit log.

**Why this exists**: during the 2026-08-20 upgrade session ([issue 08](../issues/08-upgrade-4.19.41-to-4.19.42-and-channel-drift/README.md)),
the cluster's update channel was changed twice by someone logged in as
`kube:admin` — the shared bootstrap credential. Every person who knows that
one password looks identical in the audit log, so the change could not be
traced to an individual. This checklist prevents that from happening again.

---

## Step 1 — Add the new user to the HTPasswd identity provider

**Purpose**: this cluster authenticates via HTPasswd (`oc get oauth cluster`),
backed by secret `htpasswd-secret` in `openshift-config`. A new named account
must be added to that same file — creating a *separate* secret or file does
nothing, since only `htpasswd-secret` is wired into the IdP.

```bash
# Pull the current file out of the secret so we can add to it, not replace it
oc extract secret/htpasswd-secret -n openshift-config --to=- --keys=htpasswd > /tmp/users.htpasswd

# Add the new user (prompts for password interactively — never pass it as a CLI arg)
htpasswd -B /tmp/users.htpasswd <new-username>

# Push the updated file back as the secret
oc create secret generic htpasswd-secret \
  --from-file=htpasswd=/tmp/users.htpasswd \
  -n openshift-config --dry-run=client -o yaml | oc apply -f -

# Don't leave plaintext credentials on disk
rm -f /tmp/users.htpasswd
```

## Step 2 — Grant cluster-admin to that specific user

**Purpose**: binds the `cluster-admin` ClusterRole to one named `User` object,
not a shared group or generic identity. This is what makes every subsequent
audit log entry show the real username instead of a generic identity.

```bash
oc adm policy add-cluster-role-to-user cluster-admin <new-username>
```

## Step 3 — Verify the new user can log in and has the right access

**Purpose**: confirm the account works *before* touching the shared
`kubeadmin` credential — you don't want to lock yourself out.

```bash
oc login -u <new-username> https://api.lab.ocp.local:6443
oc whoami
oc auth can-i '*' '*' --all-namespaces   # should print "yes"
```

## Step 4 — Retire the shared `kubeadmin` credential

**Purpose**: `kubeadmin` (secret `kubeadmin` in `kube-system`) is the
cluster's original bootstrap login. It is shared, unattributable, and shows
up in audit logs as `kube:admin` regardless of who actually typed the
password. As long as it exists, individual attribution is impossible for
anyone who has that password. Only delete it once Step 3 has been verified.

```bash
oc delete secret kubeadmin -n kube-system
```

> ⚠️ Irreversible without node/etcd-level recovery. Only run this after
> confirming at least one named user has working cluster-admin access.

## Step 5 — Raise the audit log profile to capture full request bodies

**Purpose**: the default audit profile (`Default`) only logs request
*metadata* (who / what resource / when) — not the actual values changed. This
is why the two channel changes in issue 08 could be traced to a user and a
timestamp, but not to the actual before/after value. `WriteRequestBodies`
logs full bodies for all mutating requests (create/update/patch/delete),
so a future config change shows exactly what changed, not just that
something did.

```bash
oc patch apiserver cluster --type=merge -p '{"spec":{"audit":{"profile":"WriteRequestBodies"}}}'
```

> This causes a rollout of the API server static pods (expected, similar
> disruption profile to a certificate rotation — no downtime, brief
> per-master restart).

## Step 6 — How to check "who changed X" going forward

**Purpose**: reusable query pattern for tracing any future config change to a
user, resource, and timestamp — this is the exact technique used to find the
`kube:admin` channel changes in issue 08.

```bash
# Find which master's apiserver handled the request (LB spreads across all 3)
for m in master-1 master-2 master-3; do
  echo "=== $m ==="
  oc debug node/${m}.lab.ocp.local -- chroot /host bash -c '
    for f in /var/log/kube-apiserver/audit*.log; do
      grep -a "\"resource\":\"<resource-plural>\"" "$f" | grep -a "\"verb\":\"patch\""
    done' 2>&1 | grep -v "^Starting\|^To use\|^Removing"
done
```

Replace `<resource-plural>` with the resource in question (e.g.
`clusterversions`, `machineconfigs`). With `WriteRequestBodies` audit level
(Step 5), the same log lines will also contain the actual patch payload.

---

## Summary Table

| Step | Action | Why |
|---|---|---|
| 1 | Add user to `htpasswd-secret` | Only file actually wired into the IdP |
| 2 | Bind `cluster-admin` to the named user | Individually attributable access |
| 3 | Verify login before proceeding | Avoid lockout |
| 4 | Delete `kubeadmin` secret | Removes the shared/unattributable credential |
| 5 | Set audit profile to `WriteRequestBodies` | Captures actual before/after values, not just metadata |
| 6 | Use per-master audit log grep | Standard procedure to trace any future change |
