# Issue 19 — Jenkins CI/CD on `lab.ocp.local`: BuildConfig Pipeline + Multibranch + Stuck Cron RCA

| Field | Detail |
|---|---|
| **Date** | 2026-09-13 |
| **Type** | Administration (new capability) + one real incident (stuck scheduler) |
| **Status** | Completed |
| **Purpose** | Stand up Jenkins on the cluster, wire a working build→deploy pipeline for a sample app with no Docker daemon available, add auto-build-on-push, then extend to a multibranch pipeline with parallel test stages |

---

## Why

Wanted a self-contained CI/CD pipeline running entirely inside the home lab —
no external Docker daemon, no public webhook exposure (the cluster is only
reachable on the home LAN, see [[reference-lab-dns-devices]]). Target app:
`github.com/esarath/jenkins-sample-app`, a minimal nginx static page.

---

## Steps Executed

### Step 1 — Deploy Jenkins

```bash
oc new-app jenkins:lts -n jenkins-install
oc expose svc/jenkins
```
Route: `jenkins-jenkins-install.apps.lab.ocp.local` (plain HTTP — fine for a
lab, noted as a gap, see Follow-ups).

**Gotcha #1 — storage**: `oc new-app` wired the Jenkins volume as `emptyDir`,
which is wiped on every pod reschedule. Fixed by creating a PVC and patching
the Deployment before doing any real setup:
```bash
oc apply -f - <<'EOF'
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: jenkins-data
spec:
  accessModes: [ReadWriteOnce]
  resources: {requests: {storage: 10Gi}}
  storageClassName: nfs-storage
EOF
oc patch deployment jenkins -n jenkins-install --type='json' -p='[
  {"op":"replace","path":"/spec/template/spec/volumes/0",
   "value":{"name":"jenkins-volume-1","persistentVolumeClaim":{"claimName":"jenkins-data"}}}
]'
```
This rolled the pod (fresh Jenkins home → new setup-wizard unlock code from
pod logs), but from then on all config/credentials/build-history survive
restarts.

**Windows hosts-file note**: `*.apps.lab.ocp.local` is a wildcard DNS entry
resolved by `svc-infra` (192.168.29.10) — Windows `hosts` files don't support
wildcards, so each new route needs its own line added manually (or point the
Windows machine's DNS at 192.168.29.10 directly to get the wildcard for free,
per [[reference-lab-dns-devices]]).

### Step 2 — First pipeline attempt: hit 3 real problems in sequence

Initial repo had an **empty Dockerfile**, no app source at all, and a
Jenkinsfile that assumed a Docker daemon (`docker build && docker push` to
`quay.io`). None of that could work — the Jenkins pod (`jenkins/jenkins:lts`)
has no Docker socket, no `docker` binary, and no `oc` binary either.

**Fix — switch to an OpenShift-native build**: added a real `Dockerfile`
(`nginxinc/nginx-unprivileged:alpine`, since default nginx needs root to
bind :80 — arbitrary-UID SCC blocks that) + `index.html`, and replaced
`docker build/push` with an OpenShift `BuildConfig` (binary source, Docker
strategy) that Jenkins triggers with `oc start-build --from-dir=.`:
```bash
oc new-build --binary --name=simple-app --strategy=docker -n jenkins-pipeline
```
No registry credentials needed — it builds straight to the internal registry
(`image-registry.openshift-image-registry.svc:5000/jenkins-pipeline/simple-app:latest`).

**Gotcha #2 — no `oc` CLI in the Jenkins pod**. Installed it once, straight
from the cluster's own downloads route (self-hosted, no internet dependency):
```bash
oc exec -n jenkins-install <pod> -- sh -c \
  'curl -sk https://downloads-openshift-console.apps.lab.ocp.local/amd64/linux/oc.tar -o /tmp/oc.tar &&
   mkdir -p /var/jenkins_home/bin && tar -xf /tmp/oc.tar -C /var/jenkins_home/bin oc &&
   chmod +x /var/jenkins_home/bin/oc'
```
Since `/var/jenkins_home` is now PVC-backed, this survives restarts. Exposed
it to every job via **Manage Jenkins → System → Global properties →
Environment variables → `PATH+EXTRA=/var/jenkins_home/bin`**.

**Gotcha #3 — `oc login` succeeded but then failed**:
```
error: KUBECONFIG is set to a file that cannot be created or modified: /.kube/config;
caused by: mkdir /.kube: permission denied
```
The container runs as an arbitrary non-root UID with `HOME=/`, so `oc`
defaults to trying to write `/.kube/config` — not writable. Fix: point
`KUBECONFIG` at a workspace-relative path in the Jenkinsfile `environment`
block:
```groovy
KUBECONFIG = "${WORKSPACE}/.kube/config"
```

RBAC for the pipeline's deploy step:
```bash
oc create serviceaccount jenkins-deployer -n jenkins-pipeline
oc policy add-role-to-user edit -z jenkins-deployer -n jenkins-pipeline
oc create token jenkins-deployer -n jenkins-pipeline --duration=8760h
```
Token stored as a Jenkins **Secret text** credential (`ocp-jenkins-pipeline-token`).

End-to-end pipeline confirmed working: checkout → `oc login` → `oc
start-build --follow` → `oc apply` + `oc rollout restart/status`. App reachable
at `simple-app-jenkins-pipeline.apps.lab.ocp.local`.

### Step 3 — Auto-build on push, without a public webhook

GitHub can't reach Jenkins (LAN-only), so used **Poll SCM**
(`H/1 * * * *`) instead of a webhook — Jenkins itself checks GitHub on a
schedule rather than waiting for an inbound push.

### Step 4 — Incident: Poll SCM configured correctly but never auto-fired

Symptom: trigger was present in `config.xml`
(`hudson.triggers.SCMTrigger`, spec `H/1 * * * *`), manually invoking it via
the Jenkins **script console** (`trig.run()`) worked instantly and correctly
detected/queued a real build — but across two separate ~5-minute observation
windows with genuine new commits pushed, it **never fired on its own**.

**RCA**: The "Jenkins cron thread" (the internal `java.util.Timer` thread
backing all periodic triggers) was alive (`Thread.getState()` = `WAITING`,
not dead) but simply never executed its per-minute sweep — confirmed by
grepping pod logs for the entire observation window: zero `SCMTrigger`
log lines except the one from the manual invocation. This is a known class
of Jenkins core bug (cron thread technically alive, functionally stuck) — no
specific plugin exception found in logs to pin down a root cause beyond that.

**Fix**: `oc rollout restart deployment/jenkins -n jenkins-install`. Safe
since Jenkins home is PVC-backed (job config/credentials/build history all
survived the restart, confirmed after). Post-restart, pushed another test
commit and this time it auto-triggered within ~4 minutes
(`"causes":[{"shortDescription":"Started by an SCM change"}]` — confirmed via
Jenkins REST API, not just observed in the UI).

**Operational takeaway**: this can recur after any Jenkins pod restart
(including the one after every lab cluster shutdown/startup cycle) — added a
check-and-fix step to the cluster startup checklist
([[reference-ocp-startup-checklist]] Step 6).

### Step 5 — Multibranch Pipeline + parallel test stages

Converted to a **Multibranch Pipeline** job (`jenkins-sample-app-mb`) so
every branch in the repo gets its own auto-built sub-job:
- Branch source: Git, `BranchDiscoveryTrait`, periodic scan every 1 min
  (same reasoning as Step 3 — no webhook available)
- Jenkinsfile restructured with a `parallel` block (3 independent checks:
  HTML/Dockerfile/deployment.yaml sanity `grep`s) run concurrently, and
  `when { branch 'main' }` guards on `OpenShift Login` / `Build Image` /
  `Deploy` so feature branches get tested but never touch the live
  deployment or overwrite the `main` image tag.
- Bumped built-in node executors 2 → 4 (**Manage Jenkins → Nodes → Built-In
  Node → Configure**) — with only 2, concurrent branches/parallel stages
  would just queue instead of actually running in parallel.
- Old single-branch job (`jenkins‑sample‑app`) disabled, not deleted, to
  avoid duplicate builds on `main` going forward.

Verified via the Jenkins REST API (`.../wfapi/describe`) rather than just the
UI: `main`'s latest build shows all 3 parallel `Test` sub-stages `SUCCESS`
followed by `OpenShift Login`/`Build Image`/`Deploy` all `SUCCESS`;
`feature/test-parallel`'s latest build shows the same 3 parallel tests
`SUCCESS` but `OpenShift Login`/`Build Image`/`Deploy` correctly
`NOT_EXECUTED`.

---

## Gotchas Worth Remembering

| Gotcha | Detail |
|---|---|
| Job name with a non-breaking hyphen | Typed/pasted `jenkins-sample-app` into the "New Item" name field but it silently became `jenkins‑sample‑app` (U+2011, non-breaking hyphen) — likely autocorrect on the client. Caused real friction: every REST/API call needed `%E2%80%91` URL-encoding instead of a plain `-`. Worth eyeballing job names after creation, especially if typed via a rich-text/autocorrect-enabled input. |
| `emptyDir` default from `oc new-app` | Always check `oc new-app`-generated Deployments for `emptyDir` volumes before treating anything as durable. |
| Arbitrary-UID container + `HOME=/` | Any tool that writes to `$HOME/.something` (kubeconfig, `.m2`, `.npm`, etc.) needs an explicit override in these non-root, no-passwd-entry containers — don't assume `$HOME` is writable. |
| Jenkins cron/SCMTrigger can silently stop firing | Not a config bug — the trigger definition was correct throughout. If Poll SCM (or any periodic trigger) stops firing with no error in the logs, suspect the internal cron thread being stuck rather than re-checking the trigger config; a Jenkins pod restart is the fix, and is safe once storage is PVC-backed. |

---

## Verification Summary

| Check | Result |
|---|---|
| Jenkins storage migrated `emptyDir` → PVC (`jenkins-data`, 10Gi, nfs-storage) | ✅ |
| `oc` CLI installed on PVC, globally on `PATH` for all jobs | ✅ |
| BuildConfig `simple-app` (binary, Docker strategy) builds to internal registry | ✅ |
| `jenkins-deployer` ServiceAccount + `edit` role + token credential | ✅ |
| Single-branch pipeline: build → deploy → route reachable, page confirmed live | ✅ |
| Poll SCM auto-build-on-push (post cron-thread-restart fix) | ✅ confirmed via API (`SCMTriggerCause`) |
| Multibranch job discovers both `main` and `feature/test-parallel` | ✅ |
| `main` build: parallel Test stages + full deploy pipeline, all `SUCCESS` | ✅ (verified via `wfapi/describe`) |
| `feature/test-parallel` build: parallel Test stages `SUCCESS`, deploy stages `NOT_EXECUTED` | ✅ (verified via `wfapi/describe`) |
| Old single-branch job disabled | ✅ |
| Cluster startup checklist updated with Jenkins cron-recovery step | ✅ |

---

## Follow-ups

- Jenkins route is plain HTTP, no TLS — acceptable for a home LAN, but the
  OCP deployer token was pasted in plaintext once during setup; rotate it
  periodically (`oc create token jenkins-deployer -n jenkins-pipeline
  --duration=8760h`, update the Jenkins credential) as a hygiene measure.
- Root cause of the stuck cron thread was not fully pinned down (no
  exception in logs) — if it recurs frequently, worth filing upstream or
  digging into a full JVM thread dump next time it happens, before
  restarting, to catch it in the act.
- Rename `jenkins‑sample‑app` (non-breaking hyphen) to a plain-ASCII name, or
  just delete it now that the multibranch job replaces it — currently only
  disabled.
- Not yet done: TLS on the Jenkins route; a real webhook path if/when the
  cluster ever gets genuine internet-facing reachability (tunnel or
  port-forward) — would let `feature/*` and `main` build near-instantly
  instead of within a ~1 minute poll window.
