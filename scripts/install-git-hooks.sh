#!/usr/bin/env bash
#
# Installs this repository's tracked git hooks (scripts/git-hooks/) into
# .git/hooks/ for the current local checkout. Hooks are never installed
# automatically by `git clone`; each clone must run this once. See "Local
# test gate" in README.md.

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
SOURCE_DIR="$REPO_ROOT/scripts/git-hooks"
TARGET_DIR="$(git -C "$REPO_ROOT" rev-parse --git-path hooks)"

mkdir -p "$TARGET_DIR"

for hook in "$SOURCE_DIR"/*; do
    hook_name="$(basename "$hook")"
    install -m 0755 "$hook" "$TARGET_DIR/$hook_name"
    echo "installed $TARGET_DIR/$hook_name"
done
