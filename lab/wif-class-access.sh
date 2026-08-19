#!/usr/bin/env bash
# Class-wide access control for the CodeMender lab — no student roster.
#
# Admission rule: any GitHub repo with the FIXED lab name (default
# `ace-module2-lab`) may impersonate the CI service account while access is
# OPEN. Two pieces implement it:
#
#   1. The provider's attribute condition:
#        assertion.repository.endsWith('/<repo-name>')
#   2. One pool-wide workloadIdentityUser binding on the SA
#      (principalSet on the whole pool — the provider condition is what
#      narrows it to the fixed repo name).
#
# `close` removes the pool-wide binding — the one-command kill switch for
# outside lab windows. Repos keep their variables; auth just starts failing
# with "unable to impersonate" until the next `open`.
#
# Trade-off, stated plainly: while OPEN, anyone on GitHub who names a repo
# `<repo-name>` can use the SA's two roles (i.e. burn Vertex AI quota on the
# shared project). Close between cohorts, keep quota caps on, and consider a
# less guessable fixed name for public catalogs.
#
# Usage:
#   ./lab/wif-class-access.sh <gcp-project-id> open [repo-name]
#   ./lab/wif-class-access.sh <gcp-project-id> close
#   ./lab/wif-class-access.sh <gcp-project-id> status
#
# Env overrides: SA_EMAIL, POOL, PROVIDER.
set -euo pipefail

PROJECT="${1:-}"
ACTION="${2:-}"
REPO_NAME="${3:-ace-module2-lab}"
POOL="${POOL:-github-actions}"
PROVIDER="${PROVIDER:-github-oidc}"

if [[ -z "$PROJECT" || ! "$ACTION" =~ ^(open|close|status)$ ]]; then
  echo "usage: $0 <gcp-project-id> open [repo-name] | close | status" >&2
  exit 2
fi

SA="${SA_EMAIL:-codemender-ci@${PROJECT}.iam.gserviceaccount.com}"
PROJECT_NUMBER=$(gcloud projects describe "$PROJECT" --format='value(projectNumber)')
POOL_MEMBER="principalSet://iam.googleapis.com/projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/${POOL}/*"

show_status() {
  echo ">> provider condition:"
  gcloud iam workload-identity-pools providers describe "$PROVIDER" \
    --project="$PROJECT" --location=global --workload-identity-pool="$POOL" \
    --format='value(attributeCondition)' | sed 's/^/   /'
  echo ">> allowed audience (WIF_AUDIENCE repo secret must match):"
  gcloud iam workload-identity-pools providers describe "$PROVIDER" \
    --project="$PROJECT" --location=global --workload-identity-pool="$POOL" \
    --format='value(oidc.allowedAudiences)' | sed 's/^/   /'
  echo ">> workloadIdentityUser members on $SA:"
  gcloud iam service-accounts get-iam-policy "$SA" --project="$PROJECT" \
    --format=json | python3 -c '
import json,sys
p=json.load(sys.stdin)
ms=[m for b in p.get("bindings",[]) if b["role"]=="roles/iam.workloadIdentityUser" for m in b["members"]]
print("\n".join("   "+m for m in ms) if ms else "   (none — class access is CLOSED)")
'
}

case "$ACTION" in
  open)
    WANT="assertion.repository.endsWith('/${REPO_NAME}')"
    HAVE=$(gcloud iam workload-identity-pools providers describe "$PROVIDER" \
      --project="$PROJECT" --location=global --workload-identity-pool="$POOL" \
      --format='value(attributeCondition)')
    if [[ "$HAVE" != "$WANT" ]]; then
      echo ">> setting provider condition: $WANT"
      gcloud iam workload-identity-pools providers update-oidc "$PROVIDER" \
        --project="$PROJECT" --location=global --workload-identity-pool="$POOL" \
        --attribute-condition="$WANT"
    else
      echo ">> provider condition already correct"
    fi
    echo ">> granting pool-wide impersonation on $SA"
    gcloud iam service-accounts add-iam-policy-binding "$SA" \
      --project="$PROJECT" --role="roles/iam.workloadIdentityUser" \
      --member="$POOL_MEMBER" >/dev/null
    echo ">> class access is OPEN for repos named '${REPO_NAME}'."
    WIF_PROVIDER="projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/${POOL}/providers/${PROVIDER}"
    AUDIENCE=$(gcloud iam workload-identity-pools providers describe "$PROVIDER" \
      --project="$PROJECT" --location=global --workload-identity-pool="$POOL" \
      --format='value(oidc.allowedAudiences)')
    cat <<EOF

Handout values — three plain VARIABLES (identical for every student, not secret):
  GCP_WIF_PROVIDER  = ${WIF_PROVIDER}
  GCP_SA_EMAIL      = ${SA}
  GCP_QUOTA_PROJECT = ${PROJECT}

…plus one repo SECRET (share via the gated lab page only, never commit it):
  WIF_AUDIENCE      = ${AUDIENCE:-"(provider accepts the default audience — no secret required)"}

Close access after the cohort:  $0 ${PROJECT} close
EOF
    ;;
  close)
    echo ">> removing pool-wide impersonation from $SA"
    gcloud iam service-accounts remove-iam-policy-binding "$SA" \
      --project="$PROJECT" --role="roles/iam.workloadIdentityUser" \
      --member="$POOL_MEMBER" >/dev/null 2>&1 \
      || echo "   (binding was not present)"
    # Belt-and-braces: also drop any legacy per-repo bindings left over from
    # the roster era, so `close` means closed.
    gcloud iam service-accounts get-iam-policy "$SA" --project="$PROJECT" \
      --format=json | python3 -c '
import json,sys
p=json.load(sys.stdin)
for b in p.get("bindings",[]):
    if b["role"]=="roles/iam.workloadIdentityUser":
        print("\n".join(b["members"]))
' | while IFS= read -r M; do
      [[ -z "$M" ]] && continue
      gcloud iam service-accounts remove-iam-policy-binding "$SA" \
        --project="$PROJECT" --role="roles/iam.workloadIdentityUser" \
        --member="$M" >/dev/null && echo "   removed: $M"
    done
    echo ">> class access is CLOSED. Pipelines now fail at auth with 'unable to impersonate'."
    ;;
  status)
    show_status
    ;;
esac
