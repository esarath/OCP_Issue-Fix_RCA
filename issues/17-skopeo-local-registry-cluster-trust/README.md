# Issue 17 — Local Skopeo Registry on `svc-infra` + Cluster Trust/Pull Wiring

| Field | Detail |
|---|---|
| **Date** | 2026-09-05 / 2026-09-06 |
| **Type** | Administration (new capability), not an incident |
| **Status** | Completed |
| **Purpose** | Give the lab a local TLS+auth container registry for mirroring/staging images, and wire `lab.ocp.local` to trust its CA and pull from it |

---

## Why

The lab previously had no local registry — every image pull for GitOps
deployments ([[Redis]], [[multi-tenancy POC]], [[car rental booking POC]])
went straight to public registries. A local registry on `svc-infra.ocp.local`
(the same box that already runs DNS/DHCP/HAProxy for the `ocp.local` domain —
see [[reference-ocp-startup-checklist]]) gives a place to mirror/stage images
without depending on external network access, and a place for `skopeo` to
copy/inspect images from.

Two-part job:
1. Stand up the registry itself (bastion-local, podman-based).
2. Make the cluster actually trust and pull from it (separate step, done after
   confirming the standalone registry worked).

---

## Steps Executed

### Step 1 — Install `skopeo` and stand up the registry (bastion-local)

```bash
sudo dnf install -y skopeo
sudo mkdir -p /opt/registry/{data,auth,certs}
sudo openssl req -newkey rsa:4096 -nodes -sha256 \
  -keyout /opt/registry/certs/registry.key \
  -x509 -days 3650 -out /opt/registry/certs/registry.crt \
  -subj "/CN=svc-infra.ocp.local" \
  -addext "subjectAltName=DNS:svc-infra.ocp.local,IP:192.168.29.10"
sudo htpasswd -Bbc /opt/registry/auth/htpasswd registry '<generated-password>'
```

Registry run as a **Podman Quadlet** (`/etc/containers/systemd/registry.container`),
not `podman generate systemd` — that command is deprecated in favor of
Quadlets on this podman version. The quadlet auto-generates and auto-enables
the systemd unit from the `.container` file (no `systemctl enable` needed —
in fact it errors "unit is transient or generated" if you try, which is
expected/harmless).

```ini
[Container]
Image=docker.io/library/registry:2
ContainerName=registry
PublishPort=5000:5000
Volume=/opt/registry/data:/var/lib/registry:Z
Volume=/opt/registry/auth:/auth:Z
Volume=/opt/registry/certs:/certs:Z
Environment=REGISTRY_AUTH=htpasswd
Environment=REGISTRY_AUTH_HTPASSWD_REALM=Registry Realm
Environment=REGISTRY_AUTH_HTPASSWD_PATH=/auth/htpasswd
Environment=REGISTRY_HTTP_TLS_CERTIFICATE=/certs/registry.crt
Environment=REGISTRY_HTTP_TLS_KEY=/certs/registry.key

[Service]
Restart=always
[Install]
WantedBy=multi-user.target
```

```bash
sudo firewall-cmd --permanent --add-port=5000/tcp && sudo firewall-cmd --reload
sudo mkdir -p /etc/containers/certs.d/svc-infra.ocp.local:5000
sudo cp /opt/registry/certs/registry.crt /etc/containers/certs.d/svc-infra.ocp.local:5000/ca.crt
```

**DNS note**: no new DNS record was needed — `svc-infra.ocp.local` is already
the authoritative name server for the `ocp.local` zone it lives in
(`named` running locally, zone file `/var/named/ocp.local.zone`), so cluster
nodes already resolve this hostname.

Verified locally:
```bash
skopeo login svc-infra.ocp.local:5000 -u registry -p '<generated-password>'
skopeo copy docker://quay.io/podman/hello:latest docker://svc-infra.ocp.local:5000/test/hello:latest
skopeo inspect docker://svc-infra.ocp.local:5000/test/hello:latest
```
All three succeeded — login, push, and read-back.

### Step 2 — Trust the registry's CA cluster-wide

```bash
oc create configmap registry-cas \
  --from-file=svc-infra.ocp.local..5000=/opt/registry/certs/registry.crt \
  -n openshift-config --dry-run=client -o yaml | oc apply -f -
oc patch image.config.openshift.io cluster --type=merge \
  -p '{"spec":{"additionalTrustedCA":{"name":"registry-cas"}}}'
```

**Gotcha to remember**: the ConfigMap key can't contain a literal `:` (illegal
in a ConfigMap key), so OpenShift's convention is `<hostname>..<port>` — two
literal dots standing in for the colon. Used `svc-infra.ocp.local..5000`
here. `image.config.openshift.io/cluster` had no prior
`additionalTrustedCA` set, so this was a clean merge patch, not a merge of
two CA bundles.

### Step 3 — Give nodes credentials to pull from the (authenticated) registry

```bash
oc get secret/pull-secret -n openshift-config -o jsonpath='{.data.\.dockerconfigjson}' \
  | base64 -d > current-pull-secret.json
# merge in {"svc-infra.ocp.local:5000": {"auth": "<base64 user:pass>", "email": "..."}}
oc set data secret/pull-secret -n openshift-config \
  --from-file=.dockerconfigjson=new-pull-secret.json
```
Confirmed the merged secret kept all four pre-existing entries
(`cloud.openshift.com`, `quay.io`, `registry.connect.redhat.com`,
`registry.redhat.io`) plus the new `svc-infra.ocp.local:5000` one — this was
a merge, not a replace.

### Step 4 — Wait out the MachineConfig rollout

Both `additionalTrustedCA` and the global pull secret are MCO-managed inputs,
so both changes triggered a `rendered-*` MachineConfig update and a rolling
node update across **both** MCPs:

```
NAME     UPDATED   UPDATING   DEGRADED
master   False     True       False
worker   False     True       False
```

Waited (background poll, ~30 min) until both flipped to
`UPDATED=True / UPDATING=False / DEGRADED=False` with all machines current —
no manual intervention needed, no pool went degraded.

### Step 5 — Prove the cluster can actually pull from it

```bash
oc new-project registry-verify
oc run test-pull --image=svc-infra.ocp.local:5000/test/hello:latest --restart=Never -n registry-verify
```
```
Pulling image "svc-infra.ocp.local:5000/test/hello:latest"
Successfully pulled image "svc-infra.ocp.local:5000/test/hello:latest" in 146ms
```
Pod scheduled to `worker-1.lab.ocp.local`, pulled and ran cleanly — confirms
both the CA trust and the pull-secret credential are actually live on the
node's kubelet/CRI-O, not just present in the API objects. Test namespace
deleted immediately after (`oc delete project registry-verify`).

---

## Verification Summary

| Check | Result |
|---|---|
| `skopeo` installed on bastion | ✅ |
| Registry container running, restart-persistent (Quadlet) | ✅ |
| Firewall port 5000/tcp open | ✅ |
| `skopeo login` / `copy` / `inspect` against the registry | ✅ (all 3) |
| `registry-cas` ConfigMap + `additionalTrustedCA` patch applied | ✅ |
| Pull secret merged with new registry auth (old entries intact) | ✅ |
| Both MCPs rolled out `UPDATED=True`, zero `DEGRADED` | ✅ |
| Real pod on a worker node pulled from `svc-infra.ocp.local:5000` | ✅ (146ms) |
| Test namespace cleaned up | ✅ |

---

## Follow-ups

- Registry auth is a single shared `registry` htpasswd user — fine for a lab,
  would need per-consumer credentials (or mTLS) for anything more than this.
- Not yet done: any `ImageDigestMirrorSet`/mirroring of upstream registries
  *through* this local one — this setup only lets workloads reference
  `svc-infra.ocp.local:5000/...` images directly, it doesn't transparently
  redirect pulls of `quay.io/...`-style references.
- If this registry's disk (`/opt/registry/data` on the bastion) fills or the
  bastion is rebuilt, the CA cert changes and both the local
  `/etc/containers/certs.d/...` trust and the cluster `registry-cas`
  ConfigMap need to be regenerated together, or every existing pull breaks.
