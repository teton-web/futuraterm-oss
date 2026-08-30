#!/usr/bin/env bash
# Publish a history-free snapshot to davidsolheim/futuraterm.
#
# This private clone's origin is teton-web/futuraterm and its git log still
# contains MacTerm-era merge subjects. Never `git push` that history to the
# public repo, never retarget origin, and never add an upstream MacTerm remote.
#
# Usage (from the private clone):
#   ./scripts/publish-public-snapshot.sh
set -euo pipefail

PUBLIC_REPO="davidsolheim/futuraterm"
PUBLIC_URL="https://github.com/${PUBLIC_REPO}.git"
ORPHAN_BRANCH="public-oss"
COMMIT_MSG="Initial public release of FuturaTerm"
SOURCE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

cd "$SOURCE_ROOT"

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "error: $SOURCE_ROOT is not a git checkout" >&2
  exit 1
fi

SOURCE_HEAD="$(git rev-parse --abbrev-ref HEAD)"
SOURCE_SHA="$(git rev-parse HEAD)"
ORIGIN_URL="$(git remote get-url origin)"

if [[ "$ORIGIN_URL" == *"${PUBLIC_REPO}"* ]]; then
  echo "error: this checkout's origin is already ${PUBLIC_REPO}; run from the private teton-web clone" >&2
  exit 1
fi
if [[ "$ORIGIN_URL" != *teton-web/futuraterm* ]]; then
  echo "error: origin is '$ORIGIN_URL', expected teton-web/futuraterm (refusing to guess)" >&2
  exit 1
fi
if [[ -n "$(git status --porcelain)" ]]; then
  echo "error: working tree is dirty; commit or stash before publishing" >&2
  git status --porcelain >&2
  exit 1
fi

echo "Scanning tracked files for secret values…"
# Assemble the regex at runtime so this file does not contain the tokens it
# searches for (git grep would otherwise match the script itself).
SECRET_RE="$(printf '%sp_|%so_|%s_pat_|BEGIN (%s |%s |EC )?PRIVATE|AKIA[0-9A-Z]{16}' gh gh github RSA OPENSSH)"
if git grep -nE "$SECRET_RE" -- ':!*.md' ':!scripts/publish-public-snapshot.sh'; then
  echo "error: refusing to publish: secret-like values in tracked files (see above)" >&2
  exit 1
fi

if [[ "$(gh api user --jq .login)" != davidsolheim ]]; then
  echo "error: gh is not authenticated as davidsolheim; stop rather than push to teton-web" >&2
  gh auth status >&2 || true
  exit 1
fi

TMP="$(mktemp -d "${TMPDIR:-/tmp}/futuraterm-public-oss.XXXXXX")"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

echo "Throwaway clone at $TMP (depth 1, then orphan — private history never leaves this dir)"
# Path clones ignore --depth; file:// is required so MacTerm-era objects
# are not copied into /tmp even briefly.
git clone --depth 1 --single-branch \
  --branch "$SOURCE_HEAD" \
  "file://${SOURCE_ROOT}" "$TMP/clone"
cd "$TMP/clone"

# Drop every ref that is not the orphan snapshot, then prune so a mistaken
# `git push --all` still cannot send teton-web objects.
git checkout --orphan "$ORPHAN_BRANCH"
# AGENTS.md repo split: codesign/notarize scripts may be public; the
# notarizing on:release job stays on teton-web only.
rm -f .github/workflows/release.yml
git add -A
if ! git diff --cached --quiet; then
  :
else
  echo "error: orphan index is empty" >&2
  exit 1
fi

# Confirm LICENSE copyrights survived the snapshot.
if ! grep -q 'Copyright (c) 2026 FuturaTerm' LICENSE || \
   ! grep -q 'Copyright (c) 2026 Macterm' LICENSE; then
  echo "error: LICENSE is missing required copyright lines" >&2
  exit 1
fi

git commit --no-verify -m "$COMMIT_MSG"

git branch | sed 's/^[* ]*//' | while IFS= read -r b; do
  [[ "$b" == "$ORPHAN_BRANCH" ]] && continue
  git branch -D "$b"
done
git tag -l | while IFS= read -r t; do
  git tag -d "$t"
done
git remote remove origin
git reflog expire --expire=now --all
git gc --prune=now --quiet

COUNT="$(git rev-list --count --all)"
if [[ "$COUNT" != 1 ]]; then
  echo "error: throwaway repo has $COUNT commits; expected 1 before push" >&2
  git log --oneline --all >&2
  exit 1
fi
if git ls-tree -r --name-only HEAD | grep -qx '.github/workflows/release.yml'; then
  echo "error: snapshot contains .github/workflows/release.yml (notarizing on:release job must stay private)" >&2
  exit 1
fi
if git grep -nE 'FUTURATERM_NOTARIZE' HEAD -- '.github/workflows'; then
  echo "error: snapshot workflows still set FUTURATERM_NOTARIZE" >&2
  exit 1
fi
if ! git cat-file -e HEAD:scripts/notarize.sh || \
   ! git cat-file -e HEAD:scripts/codesign-release.sh; then
  echo "error: snapshot is missing codesign/notarize scripts" >&2
  exit 1
fi
if git log --all --format='%s%n%b' | grep -Fi macterm; then
  echo "error: snapshot log still mentions MacTerm-as-product" >&2
  exit 1
fi
if git remote | grep -qx origin; then
  echo "error: origin remote still present on throwaway clone" >&2
  exit 1
fi

git remote add public "$PUBLIC_URL"
if git remote | grep -qx origin; then
  echo "error: origin reappeared after adding public" >&2
  exit 1
fi
if git remote get-url public | grep -Fi macterm; then
  echo "error: public remote points at MacTerm" >&2
  exit 1
fi
if git remote get-url public | grep -F 'teton-web/futuraterm'; then
  echo "error: public remote points at the private repo" >&2
  exit 1
fi

echo "Orphan commit: $(git rev-parse HEAD)"
echo "Source (not pushed): $SOURCE_HEAD $SOURCE_SHA"
echo "Throwaway remotes:"
git remote -v

if gh repo view "$PUBLIC_REPO" >/dev/null 2>&1; then
  CURRENT_MAIN="$(gh api "repos/${PUBLIC_REPO}/git/ref/heads/main" --jq .object.sha)"
  echo "Updating existing public repo $PUBLIC_REPO (main=$CURRENT_MAIN → orphan)"
  git push --force-with-lease="refs/heads/main:${CURRENT_MAIN}" public "HEAD:main"
else
  echo "Creating public repo $PUBLIC_REPO"
  gh repo create "$PUBLIC_REPO" --public --description "Native macOS terminal emulator"
  git push -u public HEAD:main
fi

echo "Published $PUBLIC_URL"
echo "Private origin was not pushed (still $ORIGIN_URL @ $SOURCE_SHA)"
