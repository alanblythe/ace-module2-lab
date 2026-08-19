#!/usr/bin/env bash
# One-time Workload Identity Federation (WIF) setup for the CodeMender lab —
# lets GitHub Actions authenticate to GCP with NO service-account key.
#
# Creates (all idempotent — safe to re-run):
#   1. A workload identity pool  ("github-actions")
#   2. A GitHub OIDC provider in it, trust-limited to ONE repo
#   3. A roles/iam.workloadIdentityUser binding so workflows from that repo
#      may impersonate the CI service account
#
# The SA itself (+ its aiplatform.user / serviceUsageConsumer grants) must
# already exist — see INSTRUCTOR.md §2a. Nothing here is a secret: the
# provider resource name and SA email that this prints are safe to share and
# go into plain GitHub repo VARIABLES, not secrets.
#
# Usage:
#   ./lab/setup-wif.sh <gcp-project-id> <owner>/<repo> [sa-email]
#   ./lab/setup-wif.sh elevate-cm-01-rt9xt4 prashantkul/ace-module2-lab
#
# sa-email defaults to codemender-ci@<project>.iam.gserviceaccount.com
set -euo pipefail

PROJECT="${1:-}"
REPO="${2:-}"
SA="${3:-}"
POOL="github-actions"
PROVIDER="github-oidc"

if [[ -z "$PROJECT" || -z "$REPO" ]]; then
  echo "usage: $0 <gcp-project-id> <owner>/<repo> [sa-email]" >&2
  exit 2
fi
[[ -z "$SA" ]] && SA="codemender-ci@${PROJECT}.iam.gserviceaccount.com"

echo ">> project: $PROJECT"
PROJECT_NUMBER=$(gcloud projects describe "$PROJECT" --format='value(projectNumber)')
echo ">> project number: $PROJECT_NUMBER"

echo ">> verifying SA exists: $SA"
gcloud iam service-accounts describe "$SA" --project="$PROJECT" \
  --format='value(email)' >/dev/null

# -- 1. pool -----------------------------------------------------------------
if gcloud iam workload-identity-pools describe "$POOL" \
     --project="$PROJECT" --location=global >/dev/null 2>&1; then
  echo ">> pool '$POOL' already exists"
else
  echo ">> creating pool '$POOL'"
  gcloud iam workload-identity-pools create "$POOL" \
    --project="$PROJECT" --location=global \
    --display-name="GitHub Actions"
fi

# -- 2. provider, trust-limited to the one repo -------------------------------
# The attribute condition is the security boundary: only OIDC tokens minted
# for workflows of exactly this repo can pass. (GCP requires a condition for
# multi-tenant issuers like GitHub's.)
if gcloud iam workload-identity-pools providers describe "$PROVIDER" \
     --project="$PROJECT" --location=global \
     --workload-identity-pool="$POOL" >/dev/null 2>&1; then
  echo ">> provider '$PROVIDER' already exists — updating its condition for $REPO"
  gcloud iam workload-identity-pools providers update-oidc "$PROVIDER" \
    --project="$PROJECT" --location=global \
    --workload-identity-pool="$POOL" \
    --attribute-condition="assertion.repository == '${REPO}'"
else
  echo ">> creating provider '$PROVIDER' (trusting only $REPO)"
  gcloud iam workload-identity-pools providers create-oidc "$PROVIDER" \
    --project="$PROJECT" --location=global \
    --workload-identity-pool="$POOL" \
    --display-name="GitHub OIDC" \
    --issuer-uri="https://token.actions.githubusercontent.com" \
    --attribute-mapping="google.subject=assertion.sub,attribute.repository=assertion.repository,attribute.repository_owner=assertion.repository_owner" \
    --attribute-condition="assertion.repository == '${REPO}'"
fi

# -- 3. let that repo's workflows impersonate the SA --------------------------
MEMBER="principalSet://iam.googleapis.com/projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/${POOL}/attribute.repository/${REPO}"
echo ">> binding workloadIdentityUser for $REPO on $SA"
gcloud iam service-accounts add-iam-policy-binding "$SA" \
  --project="$PROJECT" \
  --role="roles/iam.workloadIdentityUser" \
  --member="$MEMBER" >/dev/null
echo ">> bound."

WIF_PROVIDER="projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/${POOL}/providers/${PROVIDER}"
cat <<EOF

============================================================
WIF ready. Set these as repo VARIABLES (not secrets) on ${REPO}:

  gh variable set GCP_WIF_PROVIDER --repo ${REPO} --body "${WIF_PROVIDER}"
  gh variable set GCP_SA_EMAIL     --repo ${REPO} --body "${SA}"
  gh variable set GCP_QUOTA_PROJECT --repo ${REPO} --body "${PROJECT}"

Neither value is sensitive — the attribute condition above means they are
useless to any workflow outside ${REPO}.
============================================================
EOF
