#!/usr/bin/env bash
#
# Installs this repository's tracked git hooks (scripts/git-hooks/) into
# .git/hooks/ for the current local checkout. Hooks are never installed
# automatically by `git clone`; each clone must run this once. See "Local
# test gate" in README.md.

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
SOURCE_DIR="$REPO_ROOT/scripts/git-hooks"
TARGET_DIR="$(git -C "$REPO_ROOT" rev-parse --path-format=absolute --git-path hooks)"

mkdir -p "$TARGET_DIR"

# Refuse to discard a hook the user already maintains. Identical tracked
# hooks are safe, which keeps repeated installation idempotent.
for hook in "$SOURCE_DIR"/*; do
    hook_name="$(basename "$hook")"
    target="$TARGET_DIR/$hook_name"
    if [[ -L "$target" || ( -e "$target" && ! -f "$target" ) ]]; then
        echo "install-git-hooks: refusing to replace non-file hook path: $target" >&2
        exit 1
    fi
    if [[ -f "$target" ]] && ! cmp -s "$hook" "$target"; then
        echo "install-git-hooks: refusing to overwrite existing hook: $target" >&2
        exit 1
    fi
done

for hook in "$SOURCE_DIR"/*; do
    hook_name="$(basename "$hook")"
    target="$TARGET_DIR/$hook_name"
    install -m 0755 "$hook" "$target"
    echo "installed $target"
done
