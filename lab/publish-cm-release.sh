#!/usr/bin/env bash
# Publish the CodeMender `cm` binary as a Release asset on a repo, so that repo's
# CodeMender guardrail workflow can download it in CI with the built-in
# GITHUB_TOKEN (`gh release download <tag> --pattern cm-linux`).
#
# Run this ONCE PER STUDENT REPO (GitHub does not copy releases on fork/template).
#
# Usage:
#   ./lab/publish-cm-release.sh <owner>/<repo> /path/to/cm-linux [/path/to/cm-mac]
#
# The tag defaults to the workflow's CM_RELEASE_TAG; override with e.g.
#   CM_RELEASE_TAG=cm-cli-v0.3.0 ./lab/publish-cm-release.sh ...
#
# Get the current linux binary (public download, ~11 MB zip):
#   curl -L -o cm-linux-amd64.zip "https://artifactregistry.googleapis.com/download/v1/projects/cmoc-prod/locations/us/repositories/codemender-cli-production/files/cm%3Astable%3Acm-linux-amd64.zip:download?alt=media"
#   unzip cm-linux-amd64.zip   # -> cm
#
# Requires: gh (authenticated with `repo` scope on the target repo).
set -euo pipefail

TAG="${CM_RELEASE_TAG:-cm-cli-v0.2.0}"
REPO="${1:-}"
CM_LINUX="${2:-}"
CM_MAC="${3:-}"

if [[ -z "$REPO" || -z "$CM_LINUX" ]]; then
  echo "usage: $0 <owner>/<repo> /path/to/cm-linux [/path/to/cm-mac]" >&2
  exit 2
fi
if [[ ! -f "$CM_LINUX" ]]; then
  echo "error: cm-linux not found at: $CM_LINUX" >&2
  exit 1
fi

# Assets are uploaded with fixed names the workflow expects: cm-linux / cm-mac.
assets=( "${CM_LINUX}#cm-linux" )
[[ -n "$CM_MAC" && -f "$CM_MAC" ]] && assets+=( "${CM_MAC}#cm-mac" )

if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
  echo "Release $TAG already exists on $REPO — uploading/clobbering assets."
  gh release upload "$TAG" --repo "$REPO" --clobber "${assets[@]}"
else
  echo "Creating release $TAG on $REPO."
  gh release create "$TAG" --repo "$REPO" \
    --title "CodeMender CLI ${TAG#cm-cli-} (lab runtime)" \
    --notes "CodeMender \`cm\` CLI for the Module 2 CI/CD Guardrail lab. Downloaded in CI via the built-in GITHUB_TOKEN." \
    "${assets[@]}"
fi

echo "Done. Assets on $REPO@$TAG:"
gh release view "$TAG" --repo "$REPO" --json assets --jq '.assets[].name'
