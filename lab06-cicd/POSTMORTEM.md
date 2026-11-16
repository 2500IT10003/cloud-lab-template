# Blameless Post-mortem: Lab 06 Chaos Injection

**Repo:** https://github.com/2500IT10003/cloud-lab-template
**Live app:** https://vlsc-cicd-lab06-2500it10003.onrender.com

## 1. What happened (chaos test)

**Hypothesis (written before the run):** if a unit test fails, the `test` job exits with code 1, `package` and `deploy` are skipped, and the live service keeps its previous commit.

I changed `assert.equal(res.status, 200)` to `500` in `test/app.test.js` and pushed commit `6c22df0`. The live service was on `fc024ac` at that moment.

- Red run: https://github.com/2500IT10003/cloud-lab-template/actions/runs/43840874966 (failed in 18s)
- **Blocking gate:** `CI - Unit Tests (Node 20)` exited with code 1.
- `CI - Unit Tests (Node 22)` was cancelled by `fail-fast: true` ("The strategy configuration was canceled because test._20 failed").
- `CI - Lint` and `CI - Dependency Security Audit` passed.
- `CD - Build, Scan and Push Image` and `CD - Deploy to Render` were **skipped**, because `needs: [lint, test, audit]` was not satisfied.
- Live commit before the chaos push: `fc024acb36fe45b8bf430d0066f46ce0bd0021cc`. In the red run, `CD - Deploy to Render` was skipped, so no deploy was triggered and the service stayed on this commit (Render's Deploys tab shows no deploy between the green run at about 09:24 UTC and the revert run at about 09:42 UTC).

**Recovery:** `git revert --no-edit HEAD` (commit `50e8210`), no force-push. Green run: https://github.com/2500IT10003/cloud-lab-template/actions/runs/43842121785. The live `/api/status` then reported `50e8210356ec2dd1732d932650bc09fecd34f797`, equal to `git rev-parse HEAD`.

**Evidence (log lines):**
not ok 1 - GET /healthz returns 200 and status ok
    Expected values to be strictly equal:
  name: 'AssertionError'
  expected: 500
  actual: 200
not ok 2 - GET /api/status returns 200 and service identity
    Expected values to be strictly equal:
  name: 'AssertionError'
  expected: 500
  actual: 200

## 2. DAG and efficiency (run 43832302559)

| Job | Duration t(v) | Level |
|---|---|---|
| lint | 11 s | 0 |
| test (slower cell, Node 20) | 13 s | 0 |
| audit | 11 s | 0 |
| package | 58 s | 1 |
| deploy | 5 s | 2 |

- T_seq = 11 + 13 + 11 + 58 + 5 = **98 s**
- Critical path = max(11, 13, 11) + 58 + 5 = **76 s** (test, package, deploy)
- Speed-up S = 98 / 76 ≈ **1.29**

The gain is small because `package` and `deploy` are on the critical path and cannot run in parallel. Docker layer caching (`cache-from: type=gha`) is the lever that shortens the critical path.

## 3. Control evaluation

| Control | What it did here | Trade-off |
|---|---|---|
| `fail-fast: true` | Cancelled Node 22 when Node 20 failed, saving runner time | Hides whether Node 22 would also have failed, so there is less diagnostic information per run |
| Trivy gate (CRITICAL, `ignore-unfixed`) | Blocked a real CVE (CVE-2026-59873, `tar` 6.2.1 bundled in npm in the base image) before anything was pushed | An upstream base-image change can break an unrelated build; `ignore-unfixed` accepts risk that has no fix yet |
| Commit-SHA image tags (plus `latest`) | Every deploy is traceable to a commit and rollback is a known tag | `latest` is mutable and weaker for audit; extra tags accumulate in the registry |
| `timeout-minutes` on every job | Stops hung jobs and caps runner cost | Too small a value causes false failures (the deploy poll waits up to 6 min inside a 10 min job limit) |

**Residual risk:** third-party actions are pinned to movable tags. The `trivy-action@0.28.0` tag no longer existed on GitHub, which broke the pipeline. A moved or replaced tag could also run different code with access to the job.

## 4. Other incidents during setup (all fixed)

| Symptom | Cause | Fix |
|---|---|---|
| "Unable to resolve action trivy-action@0.28.0" | Tag no longer exists | Updated to `v0.36.0` |
| "Password required" at GHCR login | Secret `GHCR_PAT` missing (wrong names) | Created `GHCR_PAT` and `RENDER_DEPLOY_HOOK_URL` with exact names |
| "Cache export is not supported for the docker driver" | No Buildx builder | Added `docker/setup-buildx-action@v3` |
| Trivy CRITICAL finding | Vulnerable `tar` inside npm in the base image | Removed npm from the runtime image |
| Deploy hook HTTP 400 | Render service was Git-backed (Lab 04), so the image URL was rejected | Created a new image-backed Render service for Lab 06 |

## 5. Credential exposure

While creating secrets with the CLI, a classic GitHub token was typed as the secret **name** instead of the value. The token was therefore visible in `gh secret list` output and was pasted into an AI chat session. **Action taken:** token revoked and the secret deleted at `2026-11-16 10:20 UTC`; a new classic token was created with an expiry date and stored only as `GHCR_PAT`.

## 6. What went well, and preventive action

**Went well:** the failing gate blocked every later stage; production kept the previous commit; recovery used `git revert` with a visible history; secrets were masked in logs; the audit script passed 12 of 12 checks.

**Preventive action:** pin third-party actions to full commit SHAs and enable Dependabot for them, and enter secrets through the browser form or the CLI prompt only, never as a command argument.
