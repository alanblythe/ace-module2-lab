# Instructor Guide — CodeMender CI/CD Guardrail (Module 2)

Everything you need to deploy this lab to students and grade it. Student-facing
instructions are in [`README.md`](./README.md).

---

## 0. What's in the repo

| Path | Purpose |
|---|---|
| `.github/workflows/codemender-pipeline.yml` | The guardrail pipeline (provided, working) |
| `.github/scripts/cm_triage.py` | Parses `cm report -f json` → severity counts + gate decision + the top-N findings to auto-fix (`CM_FIX_LIMIT`, default 3) |
| `.github/scripts/extract_cm_diff.py` | Extracts cm's printed unified diff so CI can `git apply` it (cm doesn't always write the patch itself in a non-interactive shell) |
| `lab/README.md` | Student lab guide |
| `lab/INSTRUCTOR.md` | This file |
| `lab/bin/cm-linux` | The `cm` binary, vendored — every template copy works with zero install steps |
| `lab/publish-cm-release.sh` | Legacy helper: publish `cm` as a Release asset (only for pre-vendoring student copies) |
| `lab/setup-wif.sh` | One-time: workload-identity pool + GitHub OIDC provider + SA binding (keyless auth) |
| `lab/wif-class-access.sh` | Open/close class access (fixed-repo-name admission); prints the 3-variable handout |
| `lab/provision-student-repos.sh` | Batch-configure repos you administer (variables + audience secret + workflow perms) |
| `lab/DESIGN.md` | Design doc for the keyless (WIF) auth architecture |
| `lab/QWIKLABS.md` | Paste-ready lab write-up + verification for Qwiklabs / Skills Boost |
| `.github/workflows/wif-auth-test.yml` | Manual smoke test proving WIF works against the live cm backend |

The target app is **OWASP Juice Shop**, imported as a single clean commit. The
16 upstream Juice Shop workflows were removed so the Actions tab shows **only**
the CodeMender guardrail.

---

## 1. Distributing `cm`: vendored in the repo

The `cm` binary is **committed at `lab/bin/cm-linux`** (~29 MB) and the
workflow just copies it onto `PATH`. Every fork/template copy therefore works
with **zero install steps** — this replaced the earlier per-repo Release
download, which broke every student copy because GitHub does **not** copy
Releases on fork or "Use this template" (the release existed only on the
original repo).

To update the binary when a new `cm` version ships (public download):

```bash
curl -L -o cm-linux-amd64.zip "https://artifactregistry.googleapis.com/download/v1/projects/cmoc-prod/locations/us/repositories/codemender-cli-production/files/cm%3Astable%3Acm-linux-amd64.zip:download?alt=media"
unzip cm-linux-amd64.zip           # -> cm
install -m 0755 cm lab/bin/cm-linux && git add lab/bin/cm-linux
```

(`.gitignore` ignores stray `cm-linux` files everywhere else but explicitly
allows `lab/bin/cm-linux`.)

**Legacy:** student copies created before the binary was vendored still run
the old release-download step; either have them re-copy the template, or
publish the release onto their repo with
`./lab/publish-cm-release.sh <owner>/<repo> ./lab/bin/cm-linux`.

---

## 2. Per-repo setup checklist

### 2a. Keyless CI auth — one SA + WIF for the whole class

`cm` authenticates via **ADC** and attributes quota to `GOOGLE_CLOUD_PROJECT`.
The pipeline is **keyless**: each run exchanges its GitHub OIDC token for
short-lived credentials of one shared CI service account, via **Workload
Identity Federation**. No key file exists, so there is nothing students can
leak (or exfiltrate from a workflow), and nothing to rotate after the course —
admission is by the **fixed repo name** (`ace-module2-lab`), behind an
open/close switch you flip around each cohort.

One-time setup, in a project you control:

```bash
PROJECT=<ci-project-id>
SA=codemender-ci@$PROJECT.iam.gserviceaccount.com

gcloud services enable aiplatform.googleapis.com iamcredentials.googleapis.com \
  --project=$PROJECT
gcloud iam service-accounts create codemender-ci \
  --project=$PROJECT --display-name="CodeMender CI"

# BOTH roles are required. aiplatform.user does NOT include
# serviceusage.services.use, so without serviceUsageConsumer ADC fails with
# "Grant the caller the roles/serviceusage.serviceUsageConsumer role".
gcloud projects add-iam-policy-binding $PROJECT \
  --member="serviceAccount:$SA" --role="roles/aiplatform.user"
gcloud projects add-iam-policy-binding $PROJECT \
  --member="serviceAccount:$SA" --role="roles/serviceusage.serviceUsageConsumer"

# Pool + GitHub OIDC provider + impersonation binding for YOUR template repo
./lab/setup-wif.sh $PROJECT <owner>/ace-module2-lab
```

Then, around each cohort, flip the access switch (no student roster — any
repo named exactly `ace-module2-lab` is admitted while access is open):

```bash
./lab/wif-class-access.sh $PROJECT open     # before the session; prints the handout
./lab/wif-class-access.sh $PROJECT close    # after — the kill switch
./lab/wif-class-access.sh $PROJECT status   # what's admitted right now
```

`open` prints the **three repo variables** (identical for every student,
none of them secret) for the class handout — that's all students configure,
per README Step 2. Don't leave access open between cohorts: while open,
anyone on GitHub with a repo named `ace-module2-lab` can spend the shared
project's Vertex AI quota. That trade is deliberate (zero per-student ops);
`close` is what keeps it honest.

Notes:

- **No org-level IAM is needed** — the pool, provider, and both role grants
  are project-scoped. (Workload identity pools are project resources; the
  org-level "workforce pools" are a different product.)
- The old key-based flow (`GCP_SA_KEY` secret) is fully retired. If you ran a
  cohort on it, clean up: `gcloud iam service-accounts keys list
  --iam-account=$SA`, delete the keys, and remove the repo secrets.
- Students' sandbox roles can't create service accounts, keys, or WIF pools —
  all of this is instructor-side by design.

### 2b. Sandbox accounts running `cm` locally (Elevate)

If students get sandboxes from the **Elevate** provisioner and run
`gcloud auth application-default login` themselves, the provisioned role set
must include `serviceusage.serviceUsageConsumer` too — same reason as above.
In the provisioner's `.env`:

```
ELEVATE_CM_IAM_ROLE=roles/aiplatform.user,roles/iam.roleViewer,roles/serviceusage.serviceUsageConsumer
```

then redeploy. **Already-provisioned users don't pick this up** — either grant
the role one-off (`gcloud projects add-iam-policy-binding <project>
--member="user:<sandbox-email>" --role="roles/serviceusage.serviceUsageConsumer"`)
or release + re-provision them.

### 2c. Checklist

**Once per class (GCP side, instructor only):**

- [ ] SA + roles + pool/provider: §2a one-time setup, then `lab/setup-wif.sh`
- [ ] Set the class **audience** on the provider (a static pre-generated
      string; doubles as the `WIF_AUDIENCE` repo secret):

      ```bash
      gcloud iam workload-identity-pools providers update-oidc github-oidc \
        --project=<project> --location=global \
        --workload-identity-pool=github-actions \
        --allowed-audiences="<the pre-generated string>"
      ```

      Share the value only on the gated lab page / handout — it's the one
      thing keeping strangers who name a repo `ace-module2-lab` out while
      access is open. If it ever leaks, re-run the command with a new string.
- [ ] Open access before each cohort: `./lab/wif-class-access.sh <project> open`
      (and `close` after — don't leave it open between cohorts)

**For each student repo (self-serve on personal accounts, or batch with
`lab/provision-student-repos.sh` when you control the repos):**

- [ ] Set the three **WIF repo variables** (README Step 2 — plain variables,
      identical class-wide, printed by `wif-class-access.sh open`)
- [ ] Set the **`WIF_AUDIENCE` repo secret** (same page, Secrets tab — value
      from the handout)
- [ ] **Settings → Actions → General → Workflow permissions:**
      "Read and write permissions" **and**
      "Allow GitHub Actions to create and approve pull requests" — both ON.
      (Required for the autonomous PR; without it `create-pull-request` errors.)
- [ ] (Optional) Branch protection on `main` so the red gate actually blocks
      merges — makes the "deployment blocked" outcome tangible.

> **Heads-up on quota:** all usage lands on the `GCP_QUOTA_PROJECT` project —
> the shared-project design's one real cost. One CI project can throttle a big
> class (`RESOURCE_EXHAUSTED`), so split sections across CI projects if that
> bites (each gets its own pool via `setup-wif.sh` — five minutes of work).

---

## 3. Grading rubric

One push to `main` should produce all four artifacts. Map each criterion to
concrete, checkable evidence:

| # | Criterion | Pass evidence | Points |
|---|---|---|---|
| 1 | **Workflow execution** | Actions run exists; "Install CodeMender CLI" + "Initialize CodeMender Workspace" + "CodeMender Scan" steps are green (clean install & auth) | 25 |
| 2 | **Pipeline gating (fail-safe)** | The run is **red** because of the **"Security Gate"** step (`::error ::Deployment blocked … HIGH/CRITICAL`). A *red from an earlier crash* does **not** count | 25 |
| 3 | **Artifact generation** | Run **Summary → Artifacts** has **`codemender-report`** containing `cm-security-report.json`, and it's non-empty JSON | 25 |
| 4 | **Autonomous remediation** | A PR from branch **`codemender/auto-remediation`**, authored by the Actions bot, whose diff applies structural security fix(es) to `routes/` — e.g. a SQL injection rewritten as a parameterized query, or file-upload XXE/Zip-Slip hardened. Grade on *substance*, not a specific file (the scan is non-deterministic; the PR carries the top-N fixes). | 25 |

**Fast grading path:** open the run's **Summary** page — the "CodeMender Triage"
table shows severity counts and the remediated finding, and the Artifacts
section shows the report. Then open the **Pull requests** tab for criterion 4.

### Verify it via CLI (optional, for a TA)

```bash
R=<owner>/<repo>

# 1 & 2: latest run conclusion + that the Gate step failed
gh run list --repo "$R" --workflow "codemender-pipeline.yml" -L 1 \
  --json databaseId,conclusion,headBranch
RID=$(gh run list --repo "$R" -L 1 --json databaseId --jq '.[0].databaseId')

# 3: artifact present
gh api "repos/$R/actions/runs/$RID/artifacts" --jq '.artifacts[].name'   # → codemender-report

# 4: remediation PR present
gh pr list --repo "$R" --head codemender/auto-remediation \
  --json number,title,author,files --jq '.[] | {number,title,author:.author.login}'
```

---

## 4. Expected findings (so you know what "correct" looks like)

Scanning `routes/` reliably yields **~9–11 HIGH/CRITICAL** findings. The exact
set + ranking vary (server-side, non-deterministic); the pipeline auto-fixes the
top **N** (default 3, set by `CM_FIX_LIMIT`). The common ones:

- **SQL injection** in `routes/login.ts` / `routes/search.ts` — a string-built
  `sequelize.query(...)`. Correct fix = a **parameterized query** with bind
  `replacements`. Real `cm fix` output observed on `search.ts`:

  ```diff
  - models.sequelize.query(`SELECT * FROM Products WHERE ((name LIKE '%${criteria}%' OR description LIKE '%${criteria}%') ...)`)
  + models.sequelize.query('SELECT * FROM Products WHERE ((name LIKE :criteria OR description LIKE :criteria) ...)', { replacements: { criteria: `%${criteria}%` } })
  ```
- **File-upload** XXE / Zip-Slip / YAML-DOS in `routes/fileUpload.ts` — fix adds
  DOCTYPE/ENTITY rejection, a `startsWith(destDir)` path-traversal guard, and
  `yaml.safeLoad`.

Grade on **substance** (the vulnerability class is actually neutralized), not on
an exact file or diff — runs differ. `CM_FIX_LIMIT` in the workflow controls how
many findings each run remediates (1 = minimal single-fix lab).

---

## 5. Resetting between attempts

- Delete the remediation branch/PR: `gh pr close --delete-branch` or
  `git push origin --delete codemender/auto-remediation`.
- Re-running is idempotent: `create-pull-request` updates the existing PR rather
  than opening duplicates.

## 6. Cost / safety notes

- `cm find`/`cm fix` **upload source** to Google and let a server-side agent run
  sandboxed shell commands on the runner. Fine for Juice Shop (open source);
  communicate this to students as a real property of cloud AI security tools.
- GitHub-hosted runner minutes: a full run is typically several minutes
  (dominated by the server-side scan). Budget accordingly for large cohorts.
