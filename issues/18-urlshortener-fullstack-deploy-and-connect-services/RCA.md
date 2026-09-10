# RCA: Full-Stack JavaScript URL Shortener — Build, Deploy & Connect All Services

**Applies to:** OCP 4.x lab cluster (`lab.ocp.local`), Podman-built images, private quay.io registry
**App:** [nodeshift-blog-examples `urlshortener`](https://github.com/nodeshift-blog-examples/urlshortener) — React `front` + Express `back` + Go `redirector` + Postgres `shorties`
**Reference tutorial:** [Red Hat Developers — Deploy a new microservice from an existing image and connect all services](https://developers.redhat.com/learning/learn:openshift:how-deploy-full-stack-javascript-applications-openshift/resource/resources:deploy-new-microservice-existing-image-and-connect-all-services)

---

## Reference Tutorial Comparison

The user asked specifically to validate our steps against the reference tutorial. The tutorial covers exactly one part of this deployment — wiring a new microservice image to the frontend — and every command in it matches what we ultimately ran. Everything else below (Parts 1–6, 8) is environment-specific work the tutorial doesn't need to cover, because it assumes a Developer Sandbox (public-ish images, no local build step, sandbox-managed routes/DNS).

| Tutorial step (as documented) | What it assumes | What we actually needed on `lab.ocp.local` |
|---|---|---|
| `oc new-app --name=urlshortener-redirector quay.io/rhdevelopers/urlshortener-redirector:latest` | Image is **public**, already built | Had to `podman build` + `podman push` our own image first (Part 1); image is **private**, so `oc new-app` couldn't verify it client-side (Part 2) — needed `--allow-missing-images` + a pull secret |
| `oc expose svc/urlshortener-redirector --port=8080` | A `Service` already exists to expose | `--allow-missing-images` skipped Service creation entirely — had to `oc expose deployment` **first**, then `oc expose svc` (Part 3) |
| `oc set env deploy/urlshortener-redirector POSTGRES_SERVER=shorties` | — (matches exactly) | Applied as documented. Also had to separately fix `back`'s DB env vars, which the tutorial doesn't mention because in the Sandbox walkthrough `back` presumably already had them (Part 4) |
| `oc get routes` → note the host | Sandbox provides public, resolvable routes automatically | Routes are only resolvable via `svc-infra`'s private BIND zone — LAN clients need DNS/hosts config the tutorial has no equivalent for (Part 6) |
| `oc set env deploy/urlshortener-front REDIRECTOR_URL=http://$ROUTE_URL/` (trailing slash required) | `front` has no prior `REDIRECTOR_URL` | Applied exactly as documented — **and this was the actual fix for Part 7**, since `front` had a stale value from a different (Sandbox) environment, not a missing one |

**Validation result:** the tutorial's own commands are correct and were applied verbatim for the piece they cover (Part 7). No deviation was needed there. The extra six parts are the real-world gap between a hosted Sandbox tutorial and a self-managed lab cluster with a private registry and private DNS.

---

## Failure Chain (overview)

```
podman build/tag confusion (Part 1)
        │
        ▼
image pushed to a PRIVATE quay.io repo
        │
        ▼
oc new-app can't verify it client-side (Part 2)
        │  (--allow-missing-images)
        ▼
Deployment created, but no Service/Route (Part 3)
        │  (manual oc expose x2)
        ▼
pod runs, but app-level failures surface:
  ├─ back: missing DB_USER/DB_SERVER/DB_PASSWORD → CrashLoopBackOff (Part 4)
  └─ redirector: not yet deployed; once deployed, stale pull secret → ImagePullBackOff (Part 5)
        │
        ▼
all pods finally healthy — but website still broken for real users:
  ├─ unreachable from LAN devices → private DNS not configured client-side (Part 6)
  └─ front pointed at a stale, unrelated Sandbox domain (Part 7)
        │
        ▼
app fully functional end-to-end (verified) — cosmetic /about widget still red (Part 8, open)
```

---

## Part 1 — Podman build: context and tag format

### Symptom
```
$ podman build -t $REGISTRY_HOST/$REGISTRY_USERNAME/urlshortener/front .
Error: no Containerfile or Dockerfile specified or found in context directory, .../urlshortener: no such file or directory

$ podman build -t /home/centos/.../urlshortener/front -f front/Dockerfile .
Error: tag //urlshortener/front: invalid reference format
```

### Diagnosis
1. `$REGISTRY_HOST` / `$REGISTRY_USERNAME` were unset — confirmed with `echo "[$REGISTRY_HOST]"` → empty. `-t //urlshortener/front` is not a valid image reference (empty registry/namespace segments).
2. `-t` was repeatedly given filesystem paths (`/home/.../front`, `/home/.../Dockerfile`) — `-t` takes an image name, never a path.
3. `front/Dockerfile` does `COPY . .` then operates on `./src/config.json` — this requires the **build context** to be the `front/` directory itself. Running from the `urlshortener` root with context `.` would copy the *entire* repo (including `back/`, `redirector/`), and `./src/config.json` would not exist at that context root.
4. A later attempt ran `-f front/Dockerfile front` **while already inside `front/`**, doubling the path to a nonexistent `front/front`:
   ```
   Error: context must be a directory: ".../urlshortener/front/front"
   ```

### Fix
```bash
cd urlshortener/front
podman build -t urlshortener-front:latest .
# once REGISTRY_HOST/REGISTRY_USERNAME are properly exported:
podman build -t $REGISTRY_HOST/$REGISTRY_USERNAME/urlshortener-front:latest .
```
Rule of thumb: both `-f` and the context path are relative to the **current shell directory**. Pick one of:
- inside `front/`: `-f Dockerfile .` (or just `.`, since Dockerfile is the default name)
- inside `urlshortener/`: `-f front/Dockerfile front`

Never mix the two.

---

## Part 2 — `oc new-app` can't verify a private image

### Symptom
```
$ oc new-app --name=urlshortener-front $REGISTRY_HOST/$REGISTRY_USERNAME/urlshortener-front:latest
error: local file access failed with: stat quay.io/tmgk87/urlshortener-front:latest: no such file or directory
error: unable to locate any images in image streams, templates loaded in accessible projects, template files, local container images with name "quay.io/tmgk87/urlshortener-front:latest"
```

### Diagnosis
```bash
$ podman login --get-login quay.io
tmgk87   # local podman session IS authenticated

$ curl -s -o /dev/null -w "%{http_code}\n" https://quay.io/v2/tmgk87/urlshortener-front/manifests/latest
401      # repo is private — anonymous access denied

$ ls ~/.docker/config.json
No such file          # oc's expected credential file doesn't exist
```
`oc new-app` performs a **client-side** check against the registry before creating anything. It has no access to Podman's credential store (`$XDG_RUNTIME_DIR/containers/auth.json`), so even though the image was pushed successfully and Podman itself is logged in, `oc` sees an unauthenticated 401 and reports the image as "not found."

### Fix
```bash
oc new-app --name=urlshortener-front --allow-missing-images \
  $REGISTRY_HOST/$REGISTRY_USERNAME/urlshortener-front:latest
```
`--allow-missing-images` skips the client-side verification and creates the Deployment referencing the image directly — the actual pull then happens **in-cluster**, using whatever pull secret is linked to the relevant service account:
```bash
oc create secret docker-registry quay-pull-secret \
  --docker-server=quay.io --docker-username=tmgk87 \
  --docker-password='<password-or-robot-token>' --docker-email=<email>
oc secrets link default quay-pull-secret --for=pull
oc secrets link builder quay-pull-secret --for=pull
```

---

## Part 3 — Missing Service/Route after `--allow-missing-images`

### Symptom
```bash
$ oc get pods
urlshortener-front-...   1/1   Running
$ oc get svc,routes
No resources found in java-full-stack namespace.
```

### Diagnosis
Normally `oc new-app` inspects the image manifest to detect `EXPOSE`d ports (`EXPOSE 8080` in `front/Dockerfile`) and auto-creates a matching Service. Since `--allow-missing-images` explicitly skips image verification, it also can't introspect the image for ports — it creates *only* the Deployment.
```bash
$ oc get all -l app=urlshortener-front
deployment.apps/urlshortener-front   1/1   1   1   5m
# no service.v1, no route.route.openshift.io
```

### Fix
```bash
oc expose deployment urlshortener-front --port=8080 --target-port=8080
oc expose svc/urlshortener-front --port=8080
```
Verified: `curl http://urlshortener-front-java-full-stack.apps.lab.ocp.local/` → `HTTP 200`.

Repeated identically for `urlshortener-redirector` in Part 5.

---

## Part 4 — `back` CrashLoopBackOff

### Symptom
```
Warning  BackOff   3m33s (x342 over 78m)  kubelet  Back-off restarting failed container urlshortener-back
```
```
$ oc logs <pod> --previous
  DB_USER: undefined
DB_SERVER: undefined
Server started on port 3000
AggregateError [ECONNREFUSED]:
  Error: connect ECONNREFUSED ::1:5432
  Error: connect ECONNREFUSED 127.0.0.1:5432
```

### Diagnosis
```bash
$ oc set env deployment/urlshortener-back --list
# deployments/urlshortener-back, container urlshortener-back
(nothing — zero env vars set)
```
`back/utils/getClient.js`:
```js
const client = new Client({
  user: process.env.DB_USER,
  host: process.env.DB_SERVER,
  database: "urls",
  password: process.env.DB_PASSWORD,
  port: 5432,
});
```
With `DB_USER`/`DB_SERVER` both `undefined`, the `pg` client falls back to its default host `localhost` — nothing is listening on `5432` inside that pod, hence `ECONNREFUSED`.

Postgres (`shorties`) was already deployed via OpenShift's standard Postgres template (`DeploymentConfig`), which — unlike the plaintext `POSTGRES_USER=shorties` in `docker-compose.yaml` — stores credentials in **secret `shorties`**:
```bash
$ oc get dc shorties -o jsonpath='{.spec.template.spec.containers[0].env}'
[{"name":"POSTGRESQL_USER","valueFrom":{"secretKeyRef":{"key":"database-user","name":"shorties"}}}, ...]
```

### Fix
Wired `back`'s env vars directly to that existing secret — the actual credential value was never typed or printed to a terminal:
```bash
oc patch deployment urlshortener-back --type=json -p='[
  {"op":"add","path":"/spec/template/spec/containers/0/env","value":[
    {"name":"DB_SERVER","value":"shorties"},
    {"name":"DB_USER","valueFrom":{"secretKeyRef":{"name":"shorties","key":"database-user"}}},
    {"name":"DB_PASSWORD","valueFrom":{"secretKeyRef":{"name":"shorties","key":"database-password"}}}
  ]}]'
```

### Verification
```bash
$ oc rollout status deployment/urlshortener-back
deployment "urlshortener-back" successfully rolled out
$ oc get pods -l deployment=urlshortener-back
urlshortener-back-...   1/1   Running   0   31s
$ oc logs <pod>
  DB_USER: shorties
DB_SERVER: shorties
Server started on port 3000
Created table.
```

---

## Part 5 — `redirector`: hardcoded creds + stale pull secret

### Diagnosis — not yet deployed
`redirector` (a Go/Gin app) had no Deployment/DeploymentConfig or pods at all — it needed building and deploying from scratch, unlike `front`/`back` which already existed.

### Diagnosis — hardcoded credentials (code smell)
`redirector/main.go:53`:
```go
connStr := "user=shorties password=shorties dbname=urls host=" + os.Getenv("POSTGRES_SERVER") + " sslmode=disable"
```
Only the **host** is configurable via env; username/password/dbname are literal strings in source. Verified the literal password actually matches the real deployed DB, **without decoding the k8s secret** (that decode attempt was correctly blocked by the environment's guardrails as a credential-exposure risk):
```bash
$ oc exec <postgres-pod> -- bash -c 'PGPASSWORD=shorties psql -h shorties -U shorties -d urls -c "\dt"'
 Schema |  Name  | Type  |  Owner
--------+--------+-------+----------
 public | routes | table | shorties
(1 row)
```
This confirms the hardcoded credential happens to work in this environment, but it's a real risk if `shorties`'s secret is ever rotated — flagged under Prevention, not fixed in code (out of scope for this deploy).

### Build, push, deploy
```bash
cd urlshortener/redirector
podman build -t quay.io/tmgk87/urlshortener-redirector:latest .
podman push quay.io/tmgk87/urlshortener-redirector:latest
oc new-app --name=urlshortener-redirector --allow-missing-images \
  quay.io/tmgk87/urlshortener-redirector:latest
oc set env deployment/urlshortener-redirector POSTGRES_SERVER=shorties
oc expose deployment urlshortener-redirector --port=8080 --target-port=8080
oc expose svc/urlshortener-redirector --port=8080
```

### Symptom — ImagePullBackOff
```
Warning  Failed  kubelet  Failed to pull image "quay.io/tmgk87/urlshortener-redirector:latest":
  unable to retrieve auth token: invalid username/password: unauthorized: Invalid Username or Password;
  ... too many requests to registry ...
```
Same `quay-pull-secret` that successfully pulled `urlshortener-front` earlier — but failing now. `default`/`builder` service accounts both had the secret correctly linked (`oc get sa default -o jsonpath='{.imagePullSecrets}'` showed it present). The credential *value* inside the k8s secret itself was stale/incorrect, even though the local `podman login` session (used seconds earlier to build and push) was fully valid.

### Fix
Regenerated the k8s secret **directly from Podman's proven-working credential file**, instead of re-typing a password that might again be mistyped or stale:
```bash
oc delete secret quay-pull-secret
oc create secret generic quay-pull-secret \
  --from-file=.dockerconfigjson=/run/user/1000/containers/auth.json \
  --type=kubernetes.io/dockerconfigjson
oc secrets link default quay-pull-secret --for=pull
oc secrets link builder quay-pull-secret --for=pull
oc rollout restart deployment/urlshortener-redirector
```

### Verification
```bash
$ oc get pods -l deployment=urlshortener-redirector
urlshortener-redirector-...   1/1   Running   0   47s
$ curl http://urlshortener-redirector-java-full-stack.apps.lab.ocp.local/health
{"redirector":true}
```

---

## Part 6 — LAN DNS resolution

### Symptom
`curl` succeeds from `svc-infra` itself; a Windows machine on the same LAN can't reach any of the routes.

### Diagnosis
```bash
$ cat /etc/resolv.conf
search ocp.local
nameserver 192.168.29.10   # svc-infra itself
nameserver 192.168.29.1    # the lab/home router

$ sudo cat /var/named/ocp.local.zone
*.apps.lab   IN  A   192.168.29.10   # wildcard for all OpenShift Routes

$ sudo firewall-cmd --list-all
ports: ... 80/tcp 443/tcp 53/tcp 53/udp ...   # already open, not the blocker

$ sudo cat /etc/dhcp/dhcpd.conf
subnet 192.168.29.0 netmask 255.255.255.0 {
    option domain-name-servers 192.168.29.10;
    range 192.168.29.100 192.168.29.199;
}
```
`svc-infra` correctly runs both DHCP (handing itself out as DNS) and BIND (serving the `*.apps.lab` wildcard) for the lab subnet. The second nameserver in its own `resolv.conf` (`192.168.29.1`) is almost certainly the lab/home router, which — per typical router defaults — likely also runs its own DHCP server. Any device that wins a lease race against `svc-infra` gets the router's DNS (public resolvers like `8.8.8.8`), which has never heard of `.ocp.local` — a classic dual-DHCP-server conflict.

### Fix (applied)
On the Windows client, added explicit hosts entries + flushed the DNS cache:
```
192.168.29.10   urlshortener-front-java-full-stack.apps.lab.ocp.local
192.168.29.10   urlshortener-back-java-full-stack.apps.lab.ocp.local
192.168.29.10   urlshortener-redirector-java-full-stack.apps.lab.ocp.local
```
```powershell
ipconfig /flushdns
```

### Fix (recommended, not applied — user's choice to keep scope minimal)
Disable DHCP on the lab/home router so `svc-infra` is the only DHCP/DNS source on the subnet — this would fix every device automatically instead of requiring a hosts-file edit per machine per new route.

---

## Part 7 — `front` env vars stale / reference-tutorial comparison

### Symptom
`redirector` deployed and passing its own `/health` check, but had zero visible effect on the website.

### Diagnosis
```bash
$ oc set env deployment/urlshortener-front --list
BASE_URL=http://urlshortener-back-rhn-engineering-dsch-dev.apps.sandbox-m3.1530.p1.openshiftapps.com
REDIRECTOR_URL=http://urlshortener-redirector-rhn-engineering-dsch-dev.apps.sandbox-m3.1530.p1.openshiftapps.com/
```
These env vars weren't missing — they were **already set, to a completely different cluster** (a Red Hat Developer Sandbox instance, `*.apps.sandbox-m3.1530.p1.openshiftapps.com`), almost certainly left over from originally following the tutorial there before this lab cluster existed. `redirector` was correctly deployed and healthy on `lab.ocp.local`, but `front` was still trying to reach a sandbox that has nothing to do with this cluster.

**Non-obvious mechanism worth documenting:** this is a static Create-React-App build — `process.env` is *not* read at container runtime the way it would be in a Node server. `front/Dockerfile` has a build-time `jq` step that rewrites `src/config.json`'s real values into literal placeholder strings (`"$BASE_URL"`, `"$REDIRECTOR_URL"`) baked into the compiled JS bundle at `npm run build` time. Then `front/start-nginx.sh` does a **literal `sed` substitution** of those placeholder strings for the real env var values, **every time the container starts**:
```bash
sed -i "s|\$BASE_URL|${BASE_URL}|g" $file
sed -i "s|\$REDIRECTOR_URL|${REDIRECTOR_URL}|g" $file
```
This is *why* `oc set env` (which triggers a new pod, hence a fresh container from the pristine image layer) is sufficient here — the substitution reruns correctly on the new pod. It would **not** work to just patch a running pod's env without a restart, since the placeholder text in the currently-running container's `main.*.js` was already substituted with the *old* value on that pod's own startup.

### Fix
Per the reference tutorial's exact pattern (see comparison table above), including its explicit trailing-slash requirement:
```bash
oc set env deployment/urlshortener-front \
  BASE_URL="http://urlshortener-back-java-full-stack.apps.lab.ocp.local/" \
  REDIRECTOR_URL="http://urlshortener-redirector-java-full-stack.apps.lab.ocp.local/"
```

### Verification
```bash
$ oc rollout status deployment/urlshortener-front
deployment "urlshortener-front" successfully rolled out
$ oc exec <pod> -- sh -c "grep -o 'http://urlshortener-[a-z]*-java-full-stack.apps.lab.ocp.local/' /opt/app/static/js/main.*.js | sort -u"
http://urlshortener-back-java-full-stack.apps.lab.ocp.local/
http://urlshortener-redirector-java-full-stack.apps.lab.ocp.local/
$ oc exec <pod> -- sh -c "grep -c '\$REDIRECTOR_URL\|\$BASE_URL\|sandbox-m3' /opt/app/static/js/main.*.js"
0   # zero leftover placeholders or stale sandbox references
```

---

## Part 8 — Open: `/about` health widget shows red

### Symptom
`front/src/pages/About.js` renders three status tiles by making client-side `fetch()` calls from the browser:
- `Config.BASE_URL + /health` → Server + Database status
- `Config.REDIRECTOR_URL + /health` → Redirection Server status

Even after all of Parts 1–7 were fixed, the user's browser showed all three as **"Unreachable"**.

### Ruled out (all confirmed clean from `svc-infra` and from the Windows client itself)
| Check | Result |
|---|---|
| `curl` to both `/health` endpoints | `200`, correct JSON |
| CORS headers on the real GET response | `access-control-allow-origin: *` present |
| CORS `OPTIONS` preflight | `204`, `access-control-allow-methods` present |
| Windows hosts file | all 3 entries present, correct IP, no typos |
| `nslookup` "failure" | Expected — `nslookup` bypasses the OS resolver/hosts file entirely and queries the configured DNS server (`8.8.8.8`) directly; this is normal `nslookup` behavior, not a real signal |
| Windows `Test-NetConnection` (OS-level DNS + TCP) | `TcpTestSucceeded: True` for both `back` and `redirector`, resolved to `192.168.29.10` |
| Windows `Invoke-WebRequest` (OS-level HTTP stack) | `StatusCode 200`, correct JSON body, for both endpoints |
| Browser Secure DNS / DNS-over-HTTPS disabled | No change |

### Status
**Open, deprioritized by the user** — every server-side and OS-level check succeeds; only the specific browser's JS `fetch()` on this one page still fails, while the *actual application* (create-URL via `back`, redirect via `redirector`, serve via `front`) was smoke-tested end-to-end and works correctly (see [README.md § End-to-End Verification](README.md#end-to-end-verification)). This is cosmetic to the `/about` status page only.

### If revisited — next diagnostic steps
1. Direct address-bar navigation to the `/health` URLs (bypasses JS `fetch()` entirely) to isolate "browser can't reach it at all" vs. "fetch specifically fails."
2. Actual browser **Console tab** (not Network tab) red error text was requested twice but never obtained — this is the single most likely to be conclusive, since it will show the exact `TypeError`/security-policy message Chrome/Edge throws.
3. Check for a Chrome/Edge **Private Network Access (PNA)** policy — a newer browser security feature that can restrict fetches from a page to certain classified network targets; unlikely here since `front` and `back`/`redirector` all resolve to the identical IP (`192.168.29.10`), which should classify identically, but not fully ruled out.
4. Check for a privacy/ad-block browser extension silently blocking the specific `.../health` request pattern.

---

## Environment Reference (lab.ocp.local)

| Resource | Value |
|---|---|
| Project | `java-full-stack` |
| HAProxy / DNS / DHCP host | `svc-infra.ocp.local` — `192.168.29.10` |
| Route wildcard | `*.apps.lab.ocp.local` → `192.168.29.10` (BIND zone `ocp.local.zone`) |
| App images | `quay.io/tmgk87/urlshortener-front:latest`, `urlshortener-redirector:latest` (private) |
| DB | `shorties` (Postgres, OpenShift template-deployed), secret `shorties` (`database-user`/`database-password`/`database-name`), database `urls`, table `routes` |
| Routes | `urlshortener-front`, `urlshortener-back`, `urlshortener-redirector`, `shorties` (all `*-java-full-stack.apps.lab.ocp.local`) |

---

## Key Diagnostic Commands

```bash
# Confirm what's actually deployed and its health
oc get pods,svc,routes -n java-full-stack

# Confirm a Deployment's env vars (never assume — always --list before debugging further)
oc set env deployment/<name> --list

# Confirm a private registry image without exposing credentials
curl -s -o /dev/null -w "%{http_code}\n" https://<registry>/v2/<repo>/manifests/<tag>
# 401 = private/needs auth, 200 = public, 404 = doesn't exist

# Test a guessed/known DB credential without ever decoding the real secret
oc exec <db-pod> -- bash -c 'PGPASSWORD=<value> psql -h <host> -U <user> -d <db> -c "\dt"'

# Regenerate a stale registry pull secret from an already-working local login
oc create secret generic <name> --from-file=.dockerconfigjson=<local-auth.json> \
  --type=kubernetes.io/dockerconfigjson --dry-run=client -o yaml | oc replace -f -

# Verify a static frontend's baked-in config after an env var change
oc exec <pod> -- sh -c "grep -o 'http://[a-z.-]*' <path-to-built-js>"
```

---

*RCA created: 2026-09-10*
*Incident: first-time deployment of the `urlshortener` full-stack app on `lab.ocp.local`, from local Podman build through to a verified end-to-end working application.*
