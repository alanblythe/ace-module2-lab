# Module 2 Lab — CodeMender CI/CD Guardrail

Build an **autonomous security guardrail** into a CI/CD pipeline. When code is
pushed, Google **CodeMender** (the `cm` CLI) scans it, blocks the deployment if
it finds a HIGH/CRITICAL vulnerability, publishes a machine-readable report, and
opens a pull request that **patches the bug automatically**.

Your target application is **OWASP Juice Shop** — a deliberately vulnerable
web app. CodeMender will surface several HIGH/CRITICAL bugs in `routes/` (SQL
injection, file-upload XXE / Zip-Slip, …) and auto-patch the most severe ones.

---

## What you'll learn

- How an AI security agent (CodeMender) is wired into GitHub Actions as a
  **deployment gate**.
- The real CodeMender pipeline: `find` (scan) → `report` → `fix` (auto-patch).
- **Keyless CI auth**: why Workload Identity Federation beats long-lived
  secrets, and how to wire it.
- **Fail-safe gating**: turning a scan result into a red/green deploy decision.
- **Autonomous remediation**: an agent opening a PR with a code fix.

## How CodeMender actually works (read this first)

CodeMender is a **cloud service with a local executor**, not an on-device
scanner. The `cm` binary is a thin client: when you run `cm find`, it **uploads
your in-scope source** to Google's CodeMender service, where a server-side AI
agent reasons about vulnerabilities and drives the patch. Practically:

- **Your code leaves the machine.** Only point `cm` at code you're allowed to
  share. (Juice Shop is open source, so we're fine.)
- Auth is standard Google Cloud **ADC** (Application Default Credentials),
  with usage billed to the project in `GOOGLE_CLOUD_PROJECT` — in CI the
  workflow's auth step provides both (Step 2).
- Findings + patches are stored locally in `~/.codemender/` and read back with
  `cm report`.
- The scan is scoped to **`routes/`** in this lab — small (well under cm's
  ~10 MB per-scan upload limit) and home to the login SQL injection.

---

## Prerequisites

This repository is your lab template. It already contains:

- `.github/workflows/codemender-pipeline.yml` — the guardrail workflow.
- `.github/scripts/cm_triage.py` — turns the JSON report into a gate decision.
- `lab/bin/cm-linux` — the `cm` binary, vendored right in the repo so every
  copy of this template works without downloading anything.

> If you're an instructor setting this up for students, see
> [`INSTRUCTOR.md`](./INSTRUCTOR.md) first — there's one-time GCP setup and a
> short per-repo checklist that must be done before students start.

---

## Step 1 — Initialize the work environment

1. Open your copy of this repository on GitHub.
2. Confirm the workflow directory exists and contains the pipeline:

   ```
   .github/
     workflows/
       codemender-pipeline.yml
     scripts/
       cm_triage.py
   ```

   That's the GitHub Actions structure GitHub auto-discovers — any `*.yml` under
   `.github/workflows/` becomes a pipeline.

## Step 2 — Connect to Google Cloud (keyless)

CodeMender authenticates to Google Cloud with **Application Default
Credentials (ADC)** and bills its usage to the project in
`GOOGLE_CLOUD_PROJECT`. This lab does it **without any key or secret**, via
**Workload Identity Federation (WIF)**: each pipeline run mints a short-lived
GitHub OIDC token proving *which repository* it runs for, and Google exchanges
it for temporary CI-service-account credentials — but **only if your repo is
named exactly `ace-module2-lab`**, class access is open, and the token was
minted with the class **audience** string. The three variables aren't
confidential; the audience is the one class-shared value you should treat as
a secret (it goes in the Secrets tab and is masked in logs).

1. **Check your repo name.** It must be exactly **`ace-module2-lab`** —
   the Google Cloud side admits pipelines by that fixed name.
2. **Set three repository *variables*** (not secrets!) — your instructor
   provides the values, which are the same for the whole class:
   go to **Settings → Secrets and variables → Actions → Variables tab →
   New repository variable** and add:

   | Variable | Meaning |
   |---|---|
   | `GCP_WIF_PROVIDER` | The identity-federation provider your repo's tokens are exchanged at |
   | `GCP_SA_EMAIL` | The CI service account your pipeline impersonates |
   | `GCP_QUOTA_PROJECT` | The project that absorbs the Vertex AI usage |

3. **Set one repository *secret*** — on the same settings page, switch to the
   **Secrets tab → New repository secret** and add `WIF_AUDIENCE` with the
   value your instructor provides. This is the class-shared audience string
   Google's token exchange insists on; unlike the variables above, don't
   post it anywhere public.

4. Enable the pipeline's ability to open a remediation PR:
   go to **Settings → Actions → General → Workflow permissions**, select
   **Read and write permissions**, and check
   **Allow GitHub Actions to create and approve pull requests**. Save.

For the curious: the service account itself holds two project-level roles —
`roles/aiplatform.user` (call the CodeMender/Vertex AI service) and
`roles/serviceusage.serviceUsageConsumer` (attribute quota; `aiplatform.user`
alone lacks `serviceusage.services.use`).

> **Fail-fast notes:**
> - A missing variable or missing `WIF_AUDIENCE` secret stops the run
>   immediately at the **"Check WIF configuration"** step with an error
>   pointing back here.
> - If the config is present but the **auth step** fails at token exchange
>   (*"invalid audience"* or similar), the `WIF_AUDIENCE` value has a typo.
> - If it fails with *"unable to impersonate"*, either your repo isn't named
>   exactly `ace-module2-lab` (Step 2.1) or class access isn't open — ask
>   your instructor.

### Running `cm` locally instead? (sandbox accounts)

If you try `cm` on your own machine or Cloud Shell with a provisioned sandbox
account, mint ADC yourself:

```bash
gcloud auth application-default login
export GOOGLE_CLOUD_PROJECT=<your-sandbox-project-id>
```

Your sandbox **user** needs the same two roles on the project. If the login
fails with *"Caller does not have required permission to use project …
Grant the caller the roles/serviceusage.serviceUsageConsumer role"*, your
sandbox predates that role being granted automatically — see Troubleshooting.

## Step 3 — Understand the guardrail

Open `.github/workflows/codemender-pipeline.yml`. It runs on every push to
`main` (and on manual dispatch). The steps map directly onto real `cm` commands:

| Stage | Command | What it does |
|---|---|---|
| **Auth** | `google-github-actions/auth` | Exchanges the run's GitHub OIDC token for short-lived service-account credentials (WIF), writes the ADC file, and exports `GOOGLE_APPLICATION_CREDENTIALS` + `GOOGLE_CLOUD_PROJECT` — the env `cm` reads |
| **Install** | copy `lab/bin/cm-linux` onto `PATH` | The `cm` binary ships vendored in the repo — nothing is downloaded |
| **Init** | `cm init` | Mints the local CodeMender identity key |
| **Scan** | `cm find routes -y` | Uploads `routes/` and runs the server-side scan |
| **Report** | `cm report -f json` | Exports findings → uploaded as the **`codemender-report`** artifact |
| **Triage** | `cm_triage.py` | Counts HIGH/CRITICAL, ranks them, selects the top **N** (default 3) to fix |
| **Patch** | `cm fix <id>` (looped over top-N) | Generates + applies a security patch for each selected finding |
| **PR** | `peter-evans/create-pull-request` | Opens one remediation PR containing all the patches |
| **Gate** | (exit 1 if HIGH/CRITICAL) | Turns the run **red** and blocks deployment |

> **Why no `--fail-on=high,critical` flag?** The real `cm` has no such flag — a
> scan exits `0` whether or not it finds bugs. The **gate is something *you*
> build**: parse `cm report -f json` and fail the job on HIGH/CRITICAL. That's
> the `cm_triage.py` + "Security Gate" steps. This is the real, transferable
> pattern for wiring any scanner into a pipeline.

## Step 4 — Trigger and test the agent

Trigger a run any of these ways:

- **Manual — UI (easiest):** **Actions** tab → **CodeMender CI/CD Guardrail**
  in the left sidebar → **Run workflow** ▸ → choose `main` → **Run workflow**.
  This is the `workflow_dispatch` trigger — best for re-running on the *same*
  commit (e.g. the Part B exercise).
- **Manual — CLI:** with the [GitHub CLI](https://cli.github.com):
  ```bash
  gh workflow run codemender-pipeline.yml --repo <owner>/<repo> --ref main
  ```
- **Push:** commit anything to `main` — the `on: push` trigger fires automatically.

| Trigger | How | Opens a fix PR? |
|---|---|---|
| `workflow_dispatch` | Run workflow button / `gh workflow run` | ✅ yes |
| `push` to `main` | any commit to `main` | ✅ yes |

> The `pull_request` trigger is intentionally **not** enabled (it created
> branch-less red runs on the bot's own remediation PR and GitHub approval
> prompts). The workflow keeps the `github.event_name != 'pull_request'` guards,
> so you can re-add a `pull_request:` trigger to gate PRs if you want.

Then open the **Actions** tab and watch the run. Expect it to:

1. Install `cm` and initialize cleanly.
2. Scan `routes/` and surface multiple **HIGH/CRITICAL** findings (e.g. SQL
   injection in `routes/login.ts` / `routes/search.ts`, file-upload XXE /
   Zip-Slip in `routes/fileUpload.ts`).
3. Upload the `codemender-report` artifact.
4. Open a PR titled **"CodeMender: autonomous security remediation"** with
   patches for the top-N findings.
5. **Fail red** at the Security Gate (correct — `main` stays blocked until the
   findings are resolved).

---

## ✅ Success criteria (what you must demonstrate)

| # | Criterion | Where the evidence is |
|---|---|---|
| 1 | **Workflow executes** — clean `cm` install + init | Actions run log: "Install CodeMender CLI" + "Initialize CodeMender Workspace" steps green |
| 2 | **Pipeline gating (fail-safe)** — a HIGH/CRITICAL bug turns the run red and blocks deploy | Run is **red**; "Security Gate" step shows `error::Deployment blocked` |
| 3 | **Artifact generation** — `codemender-report` with `cm-security-report.json` | Run **Summary** → Artifacts → `codemender-report` (downloadable) |
| 4 | **Autonomous remediation** — agent-opened branch/PR with the fix | **Pull requests** tab: PR from `codemender/auto-remediation` with structural patch(es) to `routes/` (e.g. a SQL injection rewritten as a parameterized query) |

The job **Summary** also shows a "CodeMender Triage" table (severity counts +
the finding selected for remediation) — a quick at-a-glance for grading.

---

## Part B (exploration) — observe the non-determinism

CodeMender runs **server-side**, so the scan is *probabilistic*: the exact set
of findings and which one ranks #1 can shift between runs. Make that visible:

1. Trigger the pipeline **3 times** (Actions → **Run workflow**, or push small commits).
2. From each run's **Summary**, download the **`codemender-report`** artifact.
3. Compare them — note how the finding count, severities, and the remediated
   set vary run-to-run, and how each run's remediation PR differs.

**Reflect:** why does an AI security agent return different results on identical
code? What does that imply for using one as a *blocking* deployment gate?
> Hint: the gate keys off **severity counts**, not a specific finding — so it
> stays reliable as a fail-safe even as individual findings shift. The lab fixes
> the **top N** (default 3) findings per run so coverage doesn't hinge on which
> single bug happened to rank first.

## Troubleshooting

- **`gcloud auth application-default login` fails with "Grant the caller the
  roles/serviceusage.serviceUsageConsumer role"** → your account (or the CI
  service account) is missing that role on the project. This is *not* fixed by
  `roles/aiplatform.user` — that role doesn't include
  `serviceusage.services.use`. Ask your instructor to run:
  ```bash
  gcloud projects add-iam-policy-binding <project-id> \
    --member="user:<your-sandbox-email>" \
    --role="roles/serviceusage.serviceUsageConsumer"
  ```
  (or to release + re-provision your sandbox, which now grants it
  automatically), then retry the login.
- **"Authenticate to Google Cloud" step fails with "unable to impersonate"**
  → your repo isn't named exactly `ace-module2-lab`, class access isn't open
  (ask your instructor), or your `GCP_WIF_PROVIDER` / `GCP_SA_EMAIL` values
  have a typo — compare against the instructor handout.
- **Run stops at "Check WIF configuration"** → one of the three repo
  *variables* is missing or misspelled — the error lists which. Note they're
  under the **Variables** tab, not Secrets.
- **"GitHub Actions is not permitted to create or approve pull requests"** →
  you missed Step 2.4 (the workflow-permissions toggle).
- **Auth step fails at token exchange ("invalid audience" or similar)** →
  the `WIF_AUDIENCE` secret is missing or has a typo — re-paste it from the
  instructor handout (Secrets tab).
- **"cm binary missing" at the Install step** → your copy of the repo lacks
  `lab/bin/cm-linux` — re-copy the template completely (it ships the binary).
- **Run is green with 0 findings** → the scan didn't surface a HIGH/CRITICAL.
  Confirm `SCAN_PATH` is `routes` and that `routes/login.ts` still contains the
  string-built SQL query. (CodeMender runs server-side, so exact findings can
  vary run-to-run.)
- **`RESOURCE_EXHAUSTED` / quota errors** → usage is attributed to the
  service account's project; if the whole class shares one CI project,
  stagger your runs or retry.
- **Scan takes a while** → `cm find` runs a multi-round server-side agent;
  several minutes is normal. The job timeout is 45 minutes.

## Caveats to understand

- `cm find` **uploads source** to Google. Fine for Juice Shop; never point it at
  code you can't share.
- During a scan/fix, the server-side agent can run shell commands **on the
  runner** (inside a path sandbox). That's expected CodeMender behavior.
- This lab scans only `routes/`. Scanning the whole repo would exceed cm's
  ~10 MB upload limit and need chunking — out of scope here.
