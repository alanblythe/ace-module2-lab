#!/usr/bin/env bash
set -euo pipefail

# Make sure we are in the project root directory
cd "$(dirname "$0")"

echo "==========================================="
echo "   CodeMender Guardrail Lab Environment Setup"
echo "==========================================="
echo ""

# 1. Configure git settings if not already configured
echo "[1/5] Configuring global Git user settings..."
git config --global user.email "student@qwiklabs.net"
git config --global user.name "Student"

# 2. Init git repository and commit starter files locally
echo "[2/5] Initializing Git repository locally..."
if [ ! -d .git ]; then
  git init
  git add .
  git commit -m "Initialize security guardrail workspace [skip ci]"
else
  echo "Git repository already initialized. Skipping init."
  git commit --allow-empty -m "Initialize security guardrail workspace [skip ci]"
fi
git branch -M main

# 3. Prompt user to login to GitHub CLI
echo ""
echo "[3/5] Authenticating with GitHub..."
echo "--------------------------------------------------------"
echo "Follow the prompts below to authenticate."
echo "CRITICAL: If pasting a Personal Access Token (PAT),"
echo "ensure you check the box for the 'workflow' scope!"
echo "--------------------------------------------------------"
gh auth login
# 4. Automatically retrieve username from authenticated session
echo ""
echo "[4/5] Retrieving GitHub user profile..."
USERNAME=$(gh api user --jq '.login' 2>/dev/null || true)

if [ -z "$USERNAME" ]; then
  echo "Error: Failed to fetch authenticated GitHub username."
  echo "Please make sure your token is valid and has 'repo' scopes."
  exit 1
fi
echo "Successfully authenticated as: $USERNAME"

# 5. Create public repository on GitHub and push the code
echo ""
echo "[5/5] Creating public repository 'ace-module2-lab' on GitHub..."
git remote remove origin 2>/dev/null || true
if gh repo view "$USERNAME/ace-module2-lab" >/dev/null 2>&1; then
  echo "Repository '$USERNAME/ace-module2-lab' already exists on GitHub."
  echo "Adding remote origin and pushing latest commits..."
  git remote add origin "https://github.com/$USERNAME/ace-module2-lab.git"
  git push -u origin main
else
  gh repo create ace-module2-lab --public --source=. --remote=origin --push
fi

echo ""
echo "==========================================="
echo "        SETUP COMPLETED SUCCESSFULLY!      "
echo "==========================================="
echo "Your repository is ready at: https://github.com/$USERNAME/ace-module2-lab"
echo ""
