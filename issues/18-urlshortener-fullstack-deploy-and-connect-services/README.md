# Issue 18 — Full-Stack JavaScript URL Shortener: Build, Deploy & Connect All Services on OCP

| Field | Detail |
|---|---|
| **Date** | 2026-09-09 / 2026-09-10 |
| **Severity** | Medium (multiple blocking deploy issues, no data loss, no cluster impact) |
| **Status** | Resolved (app fully functional end-to-end) — one cosmetic item open, see Part 8 |
| **Affected** | New application `urlshortener` (front/back/redirector/shorties) in project `java-full-stack` |
| **Reference** | [Red Hat Developers: Deploy a new microservice from an existing image and connect all services](https://developers.redhat.com/learning/learn:openshift:how-deploy-full-stack-javascript-applications-openshift/resource/resources:deploy-new-microservice-existing-image-and-connect-all-services) |
| **Root Cause** | Seven distinct issues across the build → push → deploy → network → app-wiring chain — see Parts 1–7 below. None are in the reference tutorial's happy path; the tutorial assumes a public image, an auto-provisioned route/DNS (Developer Sandbox), and does not cover local `podman build` context rules, private-registry pull secrets, or DB credential wiring. |
| **Resolution Time** | ~1 sitting (multi-step, sequential fixes) |

---

## What this issue covers

This was a first-time deployment of the [nodeshift-blog-examples `urlshortener`](../../) full-stack app (React `front` + Express `back` + Go `redirector` + Postgres `shorties`) onto the `lab.ocp.local` cluster, built and pushed locally from `svc-infra` via Podman. The official Red Hat Developer tutorial (linked above) documents the *last* step — wiring a new microservice (`redirector`) to the frontend — but assumes a lot of infrastructure that doesn't exist on a self-hosted lab cluster (public images, sandbox-provided DNS/routes, no local build step). Every gap between the tutorial's happy path and this environment surfaced as a real, blocking error, documented part-by-part below.

---

## Part 1 — Podman build: wrong context / invalid image tag

**Symptom:**
```
Error: no Containerfile or Dockerfile specified or found in context directory, .../urlshortener: no such file or directory
Error: tag //urlshortener/front: invalid reference format
```

**Root cause:** `$REGISTRY_HOST`/`$REGISTRY_USERNAME` were unset, so `-t $REGISTRY_HOST/$REGISTRY_USERNAME/...` expanded to `-t //urlshortener/front` (invalid — a tag can't start with `//`). Separately, `-t` was given filesystem paths instead of an image name, and `front/Dockerfile` does `COPY . .` expecting `./src/config.json` directly under the **build context** — so the context must be the `front/` directory itself, not the repo root, and not `front/` a second time when already `cd`'d into it.

**Fix:**
```bash
cd urlshortener/front
podman build -t urlshortener-front:latest .
# or, from urlshortener/: podman build -t <tag> -f front/Dockerfile front
```

Full detail → [RCA.md § Part 1](RCA.md#part-1--podman-build-context-and-tag-format)

---

## Part 2 — `oc new-app`: private registry image not found

**Symptom:**
```
error: local file access failed with: stat quay.io/tmgk87/urlshortener-front:latest: no such file or directory
error: unable to locate any images in image streams, templates loaded in accessible projects...
```

**Root cause:** The quay.io repo is private (confirmed via anonymous `curl` → `401`). `oc new-app`'s client-side pre-flight check has no quay.io credentials — Podman's login (`$XDG_RUNTIME_DIR/containers/auth.json`) is a separate credential store from what `oc` reads (`~/.docker/config.json`, which didn't exist).

**Fix:** `oc new-app --allow-missing-images ...` to skip the client-side check, plus a `docker-registry` pull secret linked to `default`/`builder` service accounts so the **in-cluster** pull succeeds.

Full detail → [RCA.md § Part 2](RCA.md#part-2--oc-new-app-cant-verify-a-private-image)

---

## Part 3 — `--allow-missing-images` skips Service/Route creation

**Symptom:** Pod `Running`, but `oc get svc,routes` shows nothing for the new app.

**Root cause:** `oc new-app` normally inspects the image manifest to find `EXPOSE`d ports and auto-creates a Service. `--allow-missing-images` skips that introspection (it can't verify the image), so only the Deployment gets created.

**Fix:**
```bash
oc expose deployment <name> --port=8080 --target-port=8080
oc expose svc/<name> --port=8080
```

Full detail → [RCA.md § Part 3](RCA.md#part-3--missing-serviceroute-after---allow-missing-images)

---

## Part 4 — `back` CrashLoopBackOff: missing DB env vars

**Symptom:** `Back-off restarting failed container` (342 restarts / 78m). Logs: `DB_USER: undefined`, `DB_SERVER: undefined`, `ECONNREFUSED ::1:5432`.

**Root cause:** `back/utils/getClient.js` reads `DB_USER`/`DB_SERVER`/`DB_PASSWORD` from `process.env` with no defaults — the `pg` client silently fell back to `localhost:5432`. The Deployment had **zero** env vars set. Postgres (`shorties`) was already running, deployed from the OpenShift Postgres template, which stores credentials in **secret `shorties`** (keys `database-user`/`database-password`/`database-name`) — not the plaintext `POSTGRES_USER=shorties` style from `docker-compose.yaml`.

**Fix:** wired the Deployment's env vars to the existing secret via `secretKeyRef` (credentials never typed or printed):
```bash
oc patch deployment urlshortener-back --type=json -p='[
  {"op":"add","path":"/spec/template/spec/containers/0/env","value":[
    {"name":"DB_SERVER","value":"shorties"},
    {"name":"DB_USER","valueFrom":{"secretKeyRef":{"name":"shorties","key":"database-user"}}},
    {"name":"DB_PASSWORD","valueFrom":{"secretKeyRef":{"name":"shorties","key":"database-password"}}}
  ]}]'
```

Full detail → [RCA.md § Part 4](RCA.md#part-4--back-crashloopbackoff)

---

## Part 5 — `redirector`: hardcoded DB creds + stale pull secret

**Symptom:** Not deployed yet at all; once deployed, `ImagePullBackOff` with a mixed `Invalid Username or Password` / `too many requests` error.

**Root cause (code smell, not fixed in code — see Prevention):** `redirector/main.go:53` hardcodes `user=shorties password=shorties dbname=urls` directly in the connection string; only the host (`POSTGRES_SERVER`) comes from env. Verified the literal password actually matches the real DB (tested with `PGPASSWORD=shorties psql ...` directly against Postgres — never exposed the real secret). Separately, the `quay-pull-secret` used for `front` had gone stale/incorrect for `redirector`'s pull, even though the local `podman login` session was fully valid.

**Fix:** `oc set env deploy/urlshortener-redirector POSTGRES_SERVER=shorties`; regenerated `quay-pull-secret` directly from Podman's already-working `auth.json` rather than re-typing a password:
```bash
oc delete secret quay-pull-secret
oc create secret generic quay-pull-secret \
  --from-file=.dockerconfigjson=/run/user/1000/containers/auth.json \
  --type=kubernetes.io/dockerconfigjson
oc secrets link default quay-pull-secret --for=pull
oc secrets link builder quay-pull-secret --for=pull
oc rollout restart deployment/urlshortener-redirector
```

Full detail → [RCA.md § Part 5](RCA.md#part-5--redirector-hardcoded-creds--stale-pull-secret)

---

## Part 6 — Website unreachable from other LAN devices

**Symptom:** All routes work via `curl` from `svc-infra` itself; unreachable from a Windows machine on the same LAN.

**Root cause:** `*.apps.lab.ocp.local` is a **private wildcard DNS record** (`*.apps.lab IN A 192.168.29.10`) served only by BIND (`named`) running on `svc-infra`. `svc-infra` is also the DHCP server for the LAN and correctly hands out itself as DNS — but `svc-infra`'s own `resolv.conf` lists a second nameserver (`192.168.29.1`, the lab/home router), implying that router likely also runs its own default DHCP server. Devices that win a lease race against the router instead of `svc-infra` get public DNS (e.g. `8.8.8.8`), which has never heard of `.ocp.local`.

**Fix (applied):** added explicit Windows hosts file entries (`192.168.29.10` → each route hostname) + `ipconfig /flushdns`.
**Fix (not applied, longer-term):** disable DHCP on the lab router so `svc-infra` is the sole DHCP/DNS source on the LAN.

Full detail → [RCA.md § Part 6](RCA.md#part-6--lan-dns-resolution)

---

## Part 7 — Front pointed at a stale, unrelated environment

**Symptom:** `redirector` deployed and healthy, but had no visible effect on the website.

**Root cause:** `front`'s `BASE_URL`/`REDIRECTOR_URL` env vars were already set — to a **stale Red Hat Developer Sandbox domain** (`apps.sandbox-m3.1530.p1.openshiftapps.com`), left over from following the tutorial in a different environment before this lab cluster existed. This is exactly the gap the reference tutorial's "connect all services" step addresses — see the comparison table in [RCA.md § Part 7](RCA.md#part-7--front-env-vars-stale--reference-tutorial-comparison).

**Fix:**
```bash
oc set env deployment/urlshortener-front \
  BASE_URL="http://urlshortener-back-java-full-stack.apps.lab.ocp.local/" \
  REDIRECTOR_URL="http://urlshortener-redirector-java-full-stack.apps.lab.ocp.local/"
```
(Trailing slash required — matches the tutorial's explicit note.) Verified by `oc exec`-ing into the fresh pod and confirming the correct URLs (and zero leftover placeholders) in the compiled JS bundle.

---

## Part 8 — Open / non-blocking: `/about` health widget

The `/about` page does client-side `fetch()` calls to `back`/`redirector` `/health` to render green/red status tiles. Every server-side check is clean (curl `200`, correct CORS headers on both the real response and the `OPTIONS` preflight), and Windows `Invoke-WebRequest`/`Test-NetConnection` confirm OS-level DNS + TCP + HTTP all succeed from the client machine. Disabling browser Secure DNS (DoH) did not resolve it. **Status: open, deprioritized by the user** — the actual application (create + redirect a short URL) was smoke-tested end-to-end and works correctly; this only affects the cosmetic status widget. See [RCA.md § Part 8](RCA.md#part-8--open-about-health-widget-shows-red) for what's ruled out and what to check next if revisited.

---

## Reference Tutorial Comparison

See the full side-by-side table in [RCA.md](RCA.md#reference-tutorial-comparison) — summary: the official steps for wiring `redirector` → `front` (Part 7 above) are accurate and were applied as documented (including the easy-to-miss trailing-slash requirement), but the tutorial's scope starts *after* six other environment-specific problems (Parts 1–6) that don't exist in the Developer Sandbox it was written against.

---

## End-to-End Verification

```bash
curl http://urlshortener-back-java-full-stack.apps.lab.ocp.local/health
# {"server":true,"database":true}

curl -X POST http://urlshortener-back-java-full-stack.apps.lab.ocp.local/urls \
  -H "Content-Type: application/json" -d '{"route":"/smoketest","url":"https://example.com"}'

curl -D - -o /dev/null http://urlshortener-redirector-java-full-stack.apps.lab.ocp.local/smoketest
# HTTP/1.1 302 Found
# location: https://example.com
```

---

## Files

| File | Description |
|---|---|
| [RCA.md](RCA.md) | Full root cause analysis for all 8 parts, with command-level evidence and the reference-tutorial comparison table |

---

## Prevention

- **Build/tag discipline:** always confirm `pwd` before a relative `-f`/context path; never pass a filesystem path to `-t`.
- **Private registries:** decide up front whether app images should be public (simplest for lab/POC) or private (requires a `docker-registry` secret linked to `default`/`builder` — and that secret can go stale independently of a working local `podman login`, so if `ImagePullBackOff` persists despite a valid local login, regenerate the k8s secret from the local auth file rather than assuming the credential is the same).
- **`--allow-missing-images`:** remember it also skips Service/Route auto-creation — always follow with explicit `oc expose` x2.
- **DB credentials:** never hardcode them in application code (see `redirector/main.go` — flagged, not yet fixed). Always wire via `secretKeyRef`, never print/decode a secret to a terminal to "check" it — test connectivity with a guessed/known value instead if verification is needed without exposure.
- **Env vars carried across environments:** when redeploying an app previously run against a different cluster/sandbox, explicitly audit `oc set env <deploy> --list` for stale values before assuming a fresh deploy is truly fresh.
- **LAN DNS for lab clusters:** any device that needs to browse `*.apps.lab.ocp.local` needs either `svc-infra` (`192.168.29.10`) as its DNS server or manual hosts entries — this will recur for every new teammate/device added to the lab.
