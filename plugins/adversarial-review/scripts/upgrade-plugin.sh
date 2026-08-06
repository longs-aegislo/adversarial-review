#!/usr/bin/env bash

set -euo pipefail

MARKETPLACE_NAME="${1:-adversarial-review-local}"
PLUGIN_NAME="${2:-adversarial-review}"
CODEX_DATA_ROOT="${CODEX_HOME:-$HOME/.codex}"
STABLE_STATE_ROOT="${AR_STATE_ROOT:-${XDG_STATE_HOME:-$HOME/.local/state}/adversarial-review}"

command -v codex >/dev/null 2>&1 || {
    echo "missing dependency: codex" >&2
    exit 64
}
command -v jq >/dev/null 2>&1 || {
    echo "missing dependency: jq" >&2
    exit 64
}
command -v git >/dev/null 2>&1 || {
    echo "missing dependency: git" >&2
    exit 64
}

installed_json="$(codex plugin list --json)"
installed_version="$(jq -er --arg plugin "$PLUGIN_NAME" --arg marketplace "$MARKETPLACE_NAME" '
    first(.installed[] |
        select(.name == $plugin and .marketplaceName == $marketplace and .installed == true) |
        .version)
' <<< "$installed_json")" || {
    echo "$PLUGIN_NAME is not installed from $MARKETPLACE_NAME" >&2
    exit 64
}

legacy_state_root="$CODEX_DATA_ROOT/plugins/cache/$MARKETPLACE_NAME/$PLUGIN_NAME/$installed_version/runtime/state"
if [[ -d "$legacy_state_root" ]]; then
    mkdir -p "$STABLE_STATE_ROOT"
    mapfile -t legacy_states < <(
        find "$legacy_state_root" -mindepth 1 -maxdepth 1 -type d -print | sort
    )
    for legacy_state in "${legacy_states[@]}"; do
        state_name="${legacy_state##*/}"
        destination="$STABLE_STATE_ROOT/$state_name"
        if [[ -e "$destination" ]]; then
            if git diff --no-index --quiet -- "$legacy_state" "$destination"; then
                continue
            fi
            echo "state migration conflict: $destination already exists" >&2
            exit 73
        fi
    done
    for legacy_state in "${legacy_states[@]}"; do
        state_name="${legacy_state##*/}"
        destination="$STABLE_STATE_ROOT/$state_name"
        [[ -e "$destination" ]] && continue
        cp -R "$legacy_state" "$destination"
    done
fi

codex plugin marketplace upgrade "$MARKETPLACE_NAME" --json >/dev/null
install_json="$(codex plugin add "$PLUGIN_NAME@$MARKETPLACE_NAME" --json)"
jq -er '.installedPath' <<< "$install_json"
