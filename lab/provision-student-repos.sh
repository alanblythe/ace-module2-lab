#!/usr/bin/env bash
# Batch-provision student repos for the CodeMender lab (keyless / WIF design).
#
# Students on personal GitHub accounts can fully self-serve (paste 3 variables
# + 1 secret, flip workflow permissions). Use THIS script when the instructor
# controls the repos anyway (GitHub Classroom / org) and wants one sweep.
#
# The `cm` binary ships vendored in the repo (lab/bin/cm-linux), so there is
# no release to publish and nothing else to install.
#
# For each repo it:
#   1. Sets the three WIF repo VARIABLES (GCP_WIF_PROVIDER, GCP_SA_EMAIL,
#      GCP_QUOTA_PROJECT) — copied from a template repo you already configured.
#   2. Sets the WIF_AUDIENCE repo SECRET (value via -a; secrets can't be read
#      back from the template, so it must be passed in).
#   3. Sets workflow permissions to read/write + "allow PR creation".
#   4. Verifies and prints a summary.
#
# GCP-side admission is separate and roster-free: repos named ace-module2-lab
# are admitted whenever class access is open (lab/wif-class-access.sh open).
#
# Usage:
#   ./lab/provision-student-repos.sh -a <audience> owner/repo1 [owner/repo2 ...]
#   ./lab/provision-student-repos.sh -a <audience> -f repos.txt
#
# Options:
#   -t OWNER/REPO   Template repo to copy the three WIF variables from
#                   (default: prashantkul/ace-module2-lab).
#   -a AUDIENCE     Value for the WIF_AUDIENCE secret (printed by
#                   lab/wif-class-access.sh open; required).
#   -f FILE         File listing target repos, one <owner>/<repo> per line
#                   ('#' comments and blank lines ignored).
#
# Requires: gh authenticated with ADMIN access to every target repo.
set -uo pipefail

TEMPLATE="prashantkul/ace-module2-lab"
AUDIENCE=""
REPOS_FILE=""
REPOS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    -t) TEMPLATE="${2:-}"; shift 2 ;;
    -a) AUDIENCE="${2:-}"; shift 2 ;;
    -f) REPOS_FILE="${2:-}"; shift 2 ;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) echo "error: unknown option: $1" >&2; exit 2 ;;
    *) REPOS+=("$1"); shift ;;
  esac
done

# ---- validate inputs before touching anything remote ----------------------
fail=0
if [[ -z "$AUDIENCE" ]]; then
  echo "error: -a <audience> is required (wif-class-access.sh open prints it)" >&2; fail=1
fi

if [[ -n "$REPOS_FILE" ]]; then
  if [[ ! -f "$REPOS_FILE" ]]; then
    echo "error: repos file not found: $REPOS_FILE" >&2; fail=1
  else
    while IFS= read -r line; do
      line="${line%%#*}"; line="$(echo "$line" | tr -d '[:space:]')"
      [[ -n "$line" ]] && REPOS+=("$line")
    done < "$REPOS_FILE"
  fi
fi

if [[ ${#REPOS[@]} -eq 0 ]]; then
  echo "error: no target repos given (positional args and/or -f file)" >&2; fail=1
fi
[[ "$fail" -ne 0 ]] && exit 2

# ---- pull the three WIF values from the template repo ---------------------
echo ">> reading WIF variables from template $TEMPLATE"
declare -A WIF
for V in GCP_WIF_PROVIDER GCP_SA_EMAIL GCP_QUOTA_PROJECT; do
  WIF[$V]=$(gh variable get "$V" --repo "$TEMPLATE" --json value --jq .value 2>/dev/null || true)
  if [[ -z "${WIF[$V]}" ]]; then
    echo "error: variable $V not set on $TEMPLATE — run lab/setup-wif.sh first" >&2
    exit 1
  fi
  echo "   $V = ${WIF[$V]}"
done

echo
echo "Provisioning ${#REPOS[@]} repo(s)."
echo

declare -A RESULT
overall=0

for R in "${REPOS[@]}"; do
  echo "=============================================================="
  echo ">> $R"
  ok=1

  # -- 1. the three WIF variables --------------------------------------------
  for V in GCP_WIF_PROVIDER GCP_SA_EMAIL GCP_QUOTA_PROJECT; do
    if ! gh variable set "$V" --repo "$R" --body "${WIF[$V]}"; then
      echo "   variable $V: FAILED (need admin on $R?)"; ok=0
    fi
  done
  [[ "$ok" -eq 1 ]] && echo "   WIF variables: set"

  # -- 2. the audience secret -------------------------------------------------
  if gh secret set WIF_AUDIENCE --repo "$R" --body "$AUDIENCE"; then
    echo "   WIF_AUDIENCE secret: set"
  else
    echo "   WIF_AUDIENCE secret: FAILED"; ok=0
  fi

  # -- 3. workflow permissions ------------------------------------------------
  if gh api -X PUT "repos/$R/actions/permissions/workflow" \
       -f default_workflow_permissions=write \
       -F can_approve_pull_request_reviews=true >/dev/null; then
    echo "   workflow perms: write + PR creation"
  else
    echo "   workflow perms: FAILED"; ok=0
  fi

  # -- 4. verify ----------------------------------------------------------------
  if [[ "$ok" -eq 1 ]]; then
    v_vars=$(gh variable list --repo "$R" --json name --jq '.[].name' 2>/dev/null \
               | grep -cE '^(GCP_WIF_PROVIDER|GCP_SA_EMAIL|GCP_QUOTA_PROJECT)$' || true)
    v_sec=$(gh secret list --repo "$R" --json name --jq '.[].name' 2>/dev/null \
               | grep -cx 'WIF_AUDIENCE' || true)
    v_perms=$(gh api "repos/$R/actions/permissions/workflow" \
                --jq 'select(.default_workflow_permissions=="write" and .can_approve_pull_request_reviews==true) | "ok"' 2>/dev/null || true)
    if [[ "$v_vars" == "3" && "$v_sec" == "1" && "$v_perms" == "ok" ]]; then
      echo "   verify: all green"
    else
      echo "   verify: MISMATCH (vars=$v_vars/3 secret=$v_sec/1 perms=${v_perms:-no})"; ok=0
    fi
  fi

  if [[ "$ok" -eq 1 ]]; then RESULT["$R"]="OK"; else RESULT["$R"]="FAILED"; overall=1; fi
done

echo
echo "================== summary =================="
for R in "${REPOS[@]}"; do
  printf '  %-8s %s\n' "${RESULT[$R]}" "$R"
done
echo "============================================="
echo "GCP-side: make sure class access is open before students run:"
echo "  ./lab/wif-class-access.sh ${WIF[GCP_QUOTA_PROJECT]} open"
if [[ "$overall" -ne 0 ]]; then
  echo "Some repos FAILED — every step is idempotent, fix and re-run." >&2
fi
exit "$overall"
