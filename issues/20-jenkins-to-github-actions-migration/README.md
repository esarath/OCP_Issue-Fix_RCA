# Issue 20 — Migrate `jenkins-sample-app` CI/CD from Jenkins to GitHub Actions

| Field | Detail |
|---|---|
| **Date** | 2026-09-14 / 2026-09-15 |
| **Type** | Administration (new capability) + one blocking incident (bad workflow YAML) |
| **Status** | Completed |
| **Purpose** | Stand up a second, parallel CI/CD path for the same sample app on GitHub Actions (self-hosted runner, deploying to the same OpenShift namespace) so it can be compared side-by-side with the existing Jenkins pipeline from [[19-jenkins-cicd-multibranch-pipeline]] |

---

## Why

Evaluating GitHub Actions as an alternative/replacement for the Jenkins setup
on the same target app (`github.com/esarath/jenkins-sample-app` →
`BuildConfig simple-app` → `Deployment/simple-app` in namespace
`jenkins-pipeline`, route `simple-app-jenkins-pipeline.apps.lab.ocp.local`).
Same constraints as the Jenkins effort: cluster is LAN-only (no public
webhook target), so a **self-hosted runner** is required — GitHub-hosted
runners can't reach `api.lab.ocp.local`.

---

## Steps Executed

### Step 1 — False start: confused the ADO agent with a GitHub Actions runner

Tried reusing the existing Azure DevOps self-hosted agent tooling
(`~/ado-agent/config.sh`, already used for [[pipeline-dotnet CI/CD]]) by
pointing it at the GitHub repo:
```bash
/home/centos/ado-agent/config.sh --url https://github.com/esarath/jenkins-sample-app --token <redacted-pat>
```
**Gotcha #1**: this doesn't work — ADO's agent binary only speaks to Azure
DevOps pools, not GitHub's runner protocol. There's no such thing as
pointing an Azure Pipelines agent at a GitHub repo URL. Reverted with
`./config.sh remove` and started over with the real GitHub Actions runner
package instead.

**Security note**: the PAT used in that command is a real GitHub personal
access token and it is now sitting in plaintext in shell history on this
host. **Action item: revoke/rotate it in GitHub → Settings → Developer
settings → Personal access tokens.** Not reproduced here — treat any PAT
that touched a shell prompt as compromised and rotate it.

### Step 2 — Install the real GitHub Actions self-hosted runner

```bash
mkdir -p /home/centos/POCs/jenkins/actions-runner && cd /home/centos/POCs/jenkins/actions-runner
curl -o actions-runner-linux-x64-2.337.0.tar.gz -L \
  https://github.com/actions/runner/releases/download/v2.337.0/actions-runner-linux-x64-2.337.0.tar.gz
echo "70920811a4f8ad4328818682bca5c6469c1c942fab52448868071d0063816613  actions-runner-linux-x64-2.337.0.tar.gz" | shasum -a 256 -c
tar xzf ./actions-runner-linux-x64-2.337.0.tar.gz
./config.sh --url https://github.com/esarath/jenkins-sample-app --token <runner-registration-token-from-repo-settings>
```
Runner registered as **repo-scoped** (not org-wide), name `svc-infra`,
default pool. Registration token is short-lived/single-use (from
**Settings → Actions → Runners → New self-hosted runner**), so no need to
redact a reusable secret here — unlike the ADO PAT above.

### Step 3 — Run as a systemd service, hit an SELinux denial

```bash
sudo ./svc.sh install
sudo ./svc.sh start
sudo ./svc.sh status   # inactive/failed
```
**Gotcha #2**: `runsvc.sh` failed to execute under systemd (worked fine when
run manually as the `centos` user). Diagnosed with:
```bash
sudo journalctl -xe | grep -i denied
ls -Z /home/centos/POCs/jenkins/actions-runner/runsvc.sh
```
Confirmed it was mislabeled for SELinux (running from a home-directory path
that isn't in the default policy for executables launched by systemd). Fix
— relabel it properly instead of disabling enforcement:
```bash
sudo yum install -y policycoreutils-python-utils   # provides semanage
sudo semanage fcontext -a -t bin_t "/home/centos/POCs/jenkins/actions-runner/runsvc.sh"
sudo restorecon -v /home/centos/POCs/jenkins/actions-runner/runsvc.sh
sudo systemctl daemon-reload
sudo ./svc.sh start
sudo ./svc.sh status   # active (running)
```
`setenforce 0` was tried transiently while narrowing down the cause but was
**not** the actual fix and was **not** left in place — `getenforce` on the
host is confirmed back to `Enforcing`, and the `semanage fcontext` label is
what actually persists across reboots. Service unit ended up at
`/etc/systemd/system/actions.runner.esarath-jenkins-sample-app.svc-infra.service`,
running as user `centos`, `WantedBy=multi-user.target` (auto-starts on boot).

### Step 4 — Author the workflow, mirroring the Jenkinsfile

Branch `feature/github-actions-migration` →
`.github/workflows/build-deploy.yml`:
```yaml
name: Build and Deploy

on:
  push:
    branches: [main, '**']
  pull_request:
    branches: [main]
  workflow_dispatch:

env:
  OCP_API: https://api.lab.ocp.local:6443
  NAMESPACE: jenkins-pipeline

jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: grep -q "<html>" index.html
      - run: grep -q "^FROM" Dockerfile
      - run: 'grep -q "kind: Deployment" deployment.yaml'   # see Gotcha #3

  deploy:
    needs: test
    if: github.ref == 'refs/heads/main' && github.event_name == 'push'
    runs-on: self-hosted
    environment: production
    steps:
      - uses: actions/checkout@v4
      - name: OpenShift login
        uses: redhat-actions/oc-login@v1
        with:
          openshift_server_url: ${{ env.OCP_API }}
          openshift_token: ${{ secrets.OCP_TOKEN }}
          insecure_skip_tls_verify: true
          namespace: ${{ env.NAMESPACE }}
      - name: Build image (S2I)
        run: oc start-build simple-app --from-dir=. --follow -n ${{ env.NAMESPACE }}
      - name: Deploy
        run: |
          oc apply -f deployment.yaml -n ${{ env.NAMESPACE }}
          oc rollout restart deployment/simple-app -n ${{ env.NAMESPACE }}
          oc rollout status deployment/simple-app -n ${{ env.NAMESPACE }}
```
`test` mirrors the Jenkinsfile's 3 parallel sanity `grep`s (runs sequentially
here — fine at this scale, unlike Jenkins where they ran as a `parallel`
block). `deploy` reuses the exact same `oc` commands as the Jenkinsfile,
gated to `main`-branch pushes only via the `if:` condition, same intent as
Jenkins' `when { branch 'main' }`.

**Secret**: reused the existing `jenkins-deployer` ServiceAccount token from
[[19-jenkins-cicd-multibranch-pipeline]] (same `edit` role in
`jenkins-pipeline`) — stored as an **environment secret** named `OCP_TOKEN`
on a GitHub **Environment** called `production` (Settings → Environments →
New environment), not a plain repo secret, so the `deploy` job's
`environment: production` line is required for the secret to resolve.

### Step 5 — Open PR, hit the run failing instantly

```bash
gh pr create --base main --head feature/github-actions-migration \
  --title "Migrate CI/CD to GitHub Actions"
gh workflow run build-deploy.yml --ref feature/github-actions-migration
gh run list --branch main --limit 3
gh run view <run-id> --log-failed
```
Every run (feature branch, and after merging PR #6 into `main`) completed in
**0 seconds** with `conclusion: failure` and the CLI's generic
`"This run likely failed because of a workflow file issue"`. `gh workflow
run` even reported `Workflow does not have 'workflow_dispatch' trigger` —
despite the trigger being right there in the file — which was the tell that
GitHub couldn't parse the file *at all* (a total parse failure makes GitHub
fall back to registering zero triggers).

A same-day commit "Fix malformed workflow YAML" addressed *a* problem but
the runs kept failing identically afterward.

### Step 6 — RCA and real fix (2026-09-15, this session)

**Gotcha #3 — root cause**: the test step
```yaml
- run: grep -q "kind: Deployment" deployment.yaml
```
looks like it has a quoted string, but the **whole `run:` value** is an
unquoted (plain) YAML scalar — the double quotes around `kind: Deployment`
are just literal characters to the YAML parser, not a nested string
delimiter. A YAML plain scalar cannot contain `": "` (colon immediately
followed by a space) anywhere in it, because that sequence is reserved for
introducing a mapping value. `kind: Deployment` contains exactly that, which
broke the parse of the entire document, not just that line — confirmed
locally with a plain, unmodified:
```bash
python3 -c "import yaml; yaml.safe_load(open('.github/workflows/build-deploy.yml'))"
# yaml.scanner.ScannerError: mapping values are not allowed here, line 21, column 27
```
**Fix** — quote the entire `run:` value so the embedded colon is safely
inside a real YAML string:
```yaml
- run: 'grep -q "kind: Deployment" deployment.yaml'
```
Verified clean parse locally first, then pushed straight to `main`
(commit `4f1f311`) and watched it run:
```bash
git commit -m "Quote grep pattern in test step to fix YAML plain-scalar parse error"
git push origin main
gh run watch <run-id> --exit-status
```
Both jobs went green in ~37s (`test` in 6s, `deploy` in 37s: checkout → OC
login → S2I build → `oc apply`/rollout, all ✓). Confirmed for real on the
cluster too, not just from the green checkmark — `Deployment/simple-app` in
`jenkins-pipeline` showed a fresh rollout (`restartedAt` timestamp matching
the run, `revision: 17`, `1/1 readyReplicas`, `Available: True`).

---

## Gotchas Worth Remembering

| Gotcha | Detail |
|---|---|
| ADO agent ≠ GitHub Actions runner | `ado-agent/config.sh` only registers against Azure DevOps pools. Don't point it at a GitHub repo URL — use the dedicated `actions-runner` package from `actions/runner` releases instead. |
| Exposed PAT in shell history | Any token typed on a command line lands in `~/.bash_history` in plaintext. Rotate it — don't assume `config.sh remove` undoing the registration also invalidates the token. |
| systemd + SELinux + home-dir scripts | A script under `$HOME` run manually can still get denied when launched via systemd due to SELinux context. Diagnose with `journalctl -xe \| grep denied` / `ls -Z`, fix by relabeling (`semanage fcontext` + `restorecon`), not by `setenforce 0` — that's a diagnostic-only step, never leave enforcement disabled. |
| GitHub secrets can be Environment-scoped, not just repo-scoped | If a job sets `environment: production`, its secrets must be added under **Settings → Environments → production**, not the plain repo `Actions secrets` page — `gh secret list` (repo-level) will look empty even though the deploy step works fine. |
| Unquoted `run:` values containing `key: value`-shaped text | Any `run:` step whose command references YAML/JSON-like content (a `grep`/`sed` pattern quoting `kind: Deployment`, a JSON key, etc.) must have its **entire value** YAML-quoted, not just the inner shell string. An unquoted plain scalar containing `": "` breaks parsing of the *whole workflow file*, not just that step — and the resulting GitHub error message (0s runtime, "workflow file issue", missing triggers) gives no line number, so validate locally with `yaml.safe_load` before pushing. |
| Two CI systems now watch the same repo | The old Jenkins multibranch job (`jenkins-sample-app-mb`, still active per [[19-jenkins-cicd-multibranch-pipeline]]) and this GitHub Actions workflow both trigger on pushes to `main` — not yet decided which one to retire. |

---

## Verification Summary

| Check | Result |
|---|---|
| Self-hosted runner installed, registered to the correct repo | ✅ |
| Runner running as a systemd service, SELinux-clean, survives reboot (`multi-user.target`) | ✅ |
| Stray ADO-agent registration attempt cleanly reverted (`config.sh remove`) | ✅ |
| `OCP_TOKEN` present as an **Environment** secret on `production` (reused Jenkins' `jenkins-deployer` token) | ✅ |
| Workflow YAML validated locally (`yaml.safe_load`) before push | ✅ |
| `test` job: 3 sanity checks pass | ✅ |
| `deploy` job: OC login → S2I build → apply/rollout, all steps ✓, ~37s | ✅ |
| Cluster-side confirmation: `Deployment/simple-app` rolled out (revision 17, 1/1 ready) matching the run timestamp | ✅ |
| PR #6 (`feature/github-actions-migration` → `main`) merged | ✅ |

---

## Follow-ups

- **Revoke the exposed GitHub PAT** from Step 1 — not yet done as of this
  writing, do this first.
- Decide whether to keep both Jenkins and GitHub Actions running on this
  repo long-term, or retire one — currently both fire on every push to
  `main`.
- Not yet ported to GitHub Actions: Jenkins' **multibranch** behavior
  (per-branch auto-discovery + branch-gated deploy is only partially mirrored
  — the current workflow's `if:` gate covers the "don't deploy from feature
  branches" case, but there's no per-branch job fan-out / parallel test
  matrix like the Jenkins `parallel` block).
- Runner is single-instance on `svc-infra` — no redundancy; if that host is
  down, GitHub Actions builds queue indefinitely (same single-point-of-failure
  shape as Jenkins itself).
