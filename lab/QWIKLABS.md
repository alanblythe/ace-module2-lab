# Qwiklabs Write-Up: CodeMender CI/CD Guardrail

Ready-to-use lab content for Qwiklabs / Skills Boost. Students set up a
GitHub repo, run the guardrail workflow, and verify four outcomes. Repos are
**public** — safe here because this lab contains no secrets anywhere (auth
is keyless Workload Identity Federation; see [`DESIGN.md`](./DESIGN.md)),
and it makes verification a matter of opening URLs.

The three variable values below are already filled in for the current
shared project (they are also printed by `wif-class-access.sh open` —
update them here if the project ever changes). The `WIF_AUDIENCE` secret
value is deliberately **not** printed in this file (it sits in a public
repo): put it on the gated lab page only. There is no student roster —
admission is by the **fixed repo name** `ace-module2-lab`, and the course
team opens access before the session and closes it after. The shared,
allow-listed GCP project already exists — Qwiklabs provisions nothing.

---

## Lab instructions (student-facing)

### Setup — about 5 minutes

1. **Create your repo.** Open the course template on GitHub → **Use this
   template → Create a new repository**. Name it **exactly** `ace-module2-lab`
   (Google Cloud admits your pipeline by that name — any other name fails
   auth), owner = your account, visibility = **Public**.

2. **Add the three variables.** In your repo: **Settings → Secrets and
   variables → Actions → Variables tab → New repository variable.** Add
   these exactly (they are the same for everyone and not secret):

   | Name | Value |
   |---|---|
   | `GCP_WIF_PROVIDER` | `projects/755556523613/locations/global/workloadIdentityPools/github-actions/providers/github-oidc` |
   | `GCP_SA_EMAIL` | `codemender-ci@elevate-cm-01-rt9xt4.iam.gserviceaccount.com` |
   | `GCP_QUOTA_PROJECT` | `elevate-cm-01-rt9xt4` |

3. **Add the one secret.** On the same page, switch to the **Secrets tab →
   New repository secret**. Name: `WIF_AUDIENCE`, value: **shown on your lab
   page**. Unlike the variables, this one *is* a secret — it's what keeps
   people outside the course from using the class's Google Cloud access, so
   don't post it anywhere public.

4. **Allow the pipeline to open pull requests.** **Settings → Actions →
   General → Workflow permissions:** select **Read and write permissions**
   and check **Allow GitHub Actions to create and approve pull requests**.
   Save.

### Run — about 20 minutes, mostly waiting

5. Open the **Actions** tab → **CodeMender CI/CD Guardrail** → **Run
   workflow**. Watch it scan your code, generate a report, auto-patch the
   top findings, and open a pull request.

6. **The run ends with a red ❌ — that is success.** The Security Gate found
   HIGH/CRITICAL vulnerabilities and blocked "deployment." A green run would
   mean the guardrail failed to guard.

#### Triggering a run manually (or again)

The pipeline runs by itself on every push to `main` that touches code
(documentation-only changes are ignored). To start one by hand:

- **In the browser:** **Actions** tab → select **CodeMender CI/CD
  Guardrail** in the left sidebar → click the **Run workflow** dropdown on
  the right → keep branch `main` → green **Run workflow** button. The new
  run appears in the list a few seconds later — refresh if you don't see it.
- **From a terminal** (if you have `gh` installed and logged in):

  ```bash
  gh workflow run codemender-pipeline.yml -R <you>/ace-module2-lab
  gh run watch -R <you>/ace-module2-lab   # follow it live
  ```

- **To repeat a finished run** exactly as it was: open the run → **Re-run
  all jobs** (top right). Note each run consumes shared scan quota, so
  trigger runs deliberately rather than repeatedly.

### Verify — four checks, all in the browser

| # | Check | Where |
|---|---|---|
| 1 | Scan ran clean | The run's steps "CodeMender Scan" and "Triage Findings" are green ✅ |
| 2 | Gate blocked deployment | The step "Security Gate (fail on HIGH/CRITICAL)" is red ❌ with *"Deployment blocked"* |
| 3 | Report was produced | The run's **Summary** page lists artifact **`codemender-report`** |
| 4 | Auto-remediation PR exists | **Pull requests** tab shows **"🤖 CodeMender: autonomous security remediation"** — open it and look at the patches |

If something fails instead:

- **Run stops at "Check WIF configuration"** → a variable (step 2, Variables
  tab) or the `WIF_AUDIENCE` secret (step 3, Secrets tab) is missing or
  misspelled — the error says which.
- **Auth step fails at token exchange ("invalid audience" or similar)** →
  the `WIF_AUDIENCE` value has a typo — re-paste it from the lab page.
- **Auth step fails with "unable to impersonate"** → your repo isn't named
  exactly `ace-module2-lab`, or class access isn't open — contact the course
  team.
- **"not permitted to create or approve pull requests"** → step 4 was
  missed.
- **"cm binary missing"** → your repo copy lacks `lab/bin/cm-linux` — delete
  it and re-create from the template (the binary ships inside).

---

## Grader verification (no access needed — repos are public)

Browser: open `github.com/<student>/ace-module2-lab` → **Actions** (red
guardrail run), the run's **Summary** (artifact), **Pull requests** (bot
PR). Thirty seconds per student.

Or from a terminal, with any authenticated `gh`:

```bash
R=<student>/ace-module2-lab

# 1+2 — latest guardrail run exists and ended red (gate)
gh run list -R $R --workflow codemender-pipeline.yml -L 1

# 3 — report artifact present on that run
gh api repos/$R/actions/runs/$(gh run list -R $R -L 1 --json databaseId --jq '.[0].databaseId')/artifacts --jq '.artifacts[].name'

# 4 — remediation PR opened by the bot
gh pr list -R $R --head codemender/auto-remediation
```

Expected: run conclusion `failure` (the red gate), artifact
`codemender-report`, and one open PR titled "🤖 CodeMender: autonomous
security remediation".

---

## Course-team notes

- **Access switch:** `./lab/wif-class-access.sh <shared-project> open`
  before the session, `close` after. While open, any repo named
  `ace-module2-lab` is admitted — that's the deliberate trade for zero
  per-student ops, so don't leave it open between cohorts.
- **Template:** the `cm` binary ships committed at `lab/bin/cm-linux`, so
  student copies need no release, no download, no install (GitHub doesn't
  copy Releases to template copies — that used to be the most confusing
  failure mode, now gone). Updating the binary: INSTRUCTOR.md §1.
- **Audience secret:** `WIF_AUDIENCE` is a static pre-generated string set
  once on the WIF provider (INSTRUCTOR.md §2c). Print it **only** on the
  gated lab page — it's what keeps non-students out while access is open.
  If it ever leaks, one `gcloud … update-oidc --allowed-audiences=<new>`
  invalidates the old value; update the lab page to match.
- **Quota:** all usage bills to the shared allow-listed project. Budget ~2
  scans + 3 fix sessions per student; if a cohort throttles
  (`RESOURCE_EXHAUSTED`), add another allow-listed project per section —
  allow-listing has lead time.
- **Teardown:** `wif-class-access.sh close` — one command. Student repos
  keep three harmless public variables.
