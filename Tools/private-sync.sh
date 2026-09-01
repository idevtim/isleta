#!/bin/bash
#
# Back the unpublished files up to the private repo, from this same working tree.
#
# ## Why this exists
#
# Isleta's source lives in the public repo (idevtim/isleta). A handful of files are deliberately
# not published — the raw probe sessions, the 2.0 competitive analysis, the session hand-off, and
# the Claude Code skills and settings under `.claude/`. They are listed in `.gitignore`, so the
# public repo will never take them, but they still need to be somewhere other than one laptop.
#
# `idevtim/isleta-app` is that somewhere. It is the **private archive**: it keeps the full history
# from before Isleta was open sourced, and this script commits updates to the unpublished files on
# top of it. The *source* in that repo is frozen at the day of the split and is expected to go
# stale — the live source is the public repo. Only the paths listed below are ever staged here.
#
# Rather than keep a second checkout with duplicate copies that drift, this drives a **second git
# directory** (`.private.git/`) over the *same* working tree. The files stay exactly where they are,
# and where every reference to them expects them; only the repository they are committed to differs.
#
#     git --git-dir=.private.git --work-tree=. …
#
# `-f` on `add` is required and is not a workaround: these paths are in `.gitignore` for the
# benefit of the public repo, and forcing past it here is the entire point.
#
# **This script never runs a bare `git`.** Every call goes through `priv()`, so the public repo's
# `.git` is never a candidate for anything done here.
#
# ## Usage
#
#     Tools/private-sync.sh                  # commit and push with a dated message
#     Tools/private-sync.sh "why it changed"
#     Tools/private-sync.sh --status         # show what would be committed, change nothing

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GIT_DIR="$PROJECT_DIR/.private.git"
REMOTE="${ISLETA_PRIVATE_REMOTE:-https://github.com/idevtim/isleta-app.git}"
BRANCH="main"

# Everything the public repo refuses. Keep in step with the two blocks in `.gitignore`.
PATHS=(
  "docs/PROBES-2.0.md"
  "docs/PROBE-CALLS.md"
  "docs/PROBE-FINDER-EXTENSION.md"
  "docs/PROBE-LOCK-SCREEN.md"
  "docs/PROBE-MESSAGING.md"
  "docs/PROBE-SHARE-LINK.md"
  "docs/PLAN-2.0.md"
  "docs/NEXT-SESSION.md"
  "docs/BRIEF.md"
  ".claude/settings.json"
  ".claude/skills"
)

priv() { git --git-dir="$GIT_DIR" --work-tree="$PROJECT_DIR" "$@"; }

if [ ! -d "$GIT_DIR" ]; then
  echo "==> first run — initializing .private.git against $REMOTE"
  # Note the ordering: `init` is given only --git-dir, so it creates the repository at $GIT_DIR and
  # cannot touch $PROJECT_DIR/.git. Never add --separate-git-dir here; pointed at the project it
  # would replace the public repo's .git with a link file.
  mkdir -p "$GIT_DIR"
  git --git-dir="$GIT_DIR" init --quiet
  git --git-dir="$GIT_DIR" config core.bare false
  priv remote add origin "$REMOTE"
  echo "==> fetching $BRANCH (this is the full archive, so it may take a moment)"
  priv fetch --quiet origin "$BRANCH"
  priv symbolic-ref HEAD "refs/heads/$BRANCH"
  # Adopt the archive's history and index WITHOUT touching a single file in the working tree.
  # --mixed moves HEAD and the index only; the working tree is left exactly as it is.
  priv reset --mixed --quiet "origin/$BRANCH"
  # Belt and braces: this git dir must never discover an untracked file on its own.
  mkdir -p "$GIT_DIR/info"
  printf '/*\n' > "$GIT_DIR/info/exclude"
fi

existing=()
for p in "${PATHS[@]}"; do
  [ -e "$PROJECT_DIR/$p" ] && existing+=("$p")
done

if [ ${#existing[@]} -eq 0 ]; then
  echo "❌ none of the private paths exist — is this the right working tree?"
  exit 1
fi

# Only the listed paths are ever staged. Anything else in the index stays at the archive's state.
priv add -f -- "${existing[@]}"

if [ "${1:-}" = "--status" ]; then
  echo "==> staged against the private archive:"
  priv diff --cached --stat
  exit 0
fi

if priv diff --cached --quiet; then
  echo "==> nothing to sync"
  exit 0
fi

MESSAGE="${1:-chore: sync the unpublished record ($(date +%Y-%m-%d))}"
priv commit --quiet -m "$MESSAGE"
echo "==> committed: $MESSAGE"
priv push origin "$BRANCH"
echo "==> pushed to $REMOTE"
