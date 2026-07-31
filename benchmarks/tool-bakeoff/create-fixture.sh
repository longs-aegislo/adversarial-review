#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CASE_NAME="${1:-}"
DESTINATION="${2:-}"

case "$CASE_NAME" in
    pure-review|scope|fix-loop)
        ;;
    *)
        echo "usage: $0 <pure-review|scope|fix-loop> <empty-destination>" >&2
        exit 2
        ;;
esac

if [[ -z "$DESTINATION" ]]; then
    echo "usage: $0 <pure-review|scope|fix-loop> <empty-destination>" >&2
    exit 2
fi

if [[ -e "$DESTINATION" ]] && [[ -n "$(find "$DESTINATION" -mindepth 1 -print -quit 2>/dev/null)" ]]; then
    echo "destination must not exist or must be empty: $DESTINATION" >&2
    exit 2
fi

mkdir -p "$DESTINATION"
cp -R "$SCRIPT_DIR/cases/$CASE_NAME/base/." "$DESTINATION"

git -C "$DESTINATION" init -q
git -C "$DESTINATION" config user.name "Bake-off Fixture"
git -C "$DESTINATION" config user.email "fixture@example.invalid"
git -C "$DESTINATION" add .
git -C "$DESTINATION" commit -qm "fixture: establish baseline"
git -C "$DESTINATION" tag benchmark-base

cp -R "$SCRIPT_DIR/cases/$CASE_NAME/change/." "$DESTINATION"
git -C "$DESTINATION" add .
git -C "$DESTINATION" commit -qm "fixture: add flawed implementation"

printf 'case=%s\n' "$CASE_NAME"
printf 'path=%s\n' "$(cd "$DESTINATION" && pwd)"
printf 'base=%s\n' "$(git -C "$DESTINATION" rev-parse benchmark-base)"
printf 'head=%s\n' "$(git -C "$DESTINATION" rev-parse HEAD)"
