#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${PLUGIN_RELEASE_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
PLUGIN_ROOT="$REPO_ROOT/plugins/adversarial-review"
MANIFEST="$PLUGIN_ROOT/.codex-plugin/plugin.json"
COMPATIBILITY="$PLUGIN_ROOT/compatibility.json"
MARKETPLACE="$REPO_ROOT/.agents/plugins/marketplace.json"
METADATA_ONLY=false

fail() {
    echo "release gate failed: $1" >&2
    exit 1
}

usage() {
    cat <<'EOF'
Usage: scripts/validate-plugin-release.sh [--metadata-only]

Validate Plugin release metadata, then run deterministic clean-profile package
and Git lifecycle acceptance. --metadata-only skips the acceptance suites.
EOF
}

case "${1:-}" in
    "") ;;
    --metadata-only) METADATA_ONLY=true ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; fail "unknown argument: $1" ;;
esac
[[ $# -le 1 ]] || fail "too many arguments"

command -v jq >/dev/null 2>&1 || fail "jq is required"
[[ -f "$MANIFEST" ]] || fail "Plugin manifest is missing"
[[ -f "$COMPATIBILITY" ]] || fail "compatibility metadata is missing"
[[ -f "$MARKETPLACE" ]] || fail "marketplace metadata is missing"

VERSION="$(jq -er '.version' "$MANIFEST")" || fail "manifest version is missing"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "manifest version must be a semantic version"
[[ "$(jq -r '.name' "$MANIFEST")" == "adversarial-review" ]] ||
    fail "stable Plugin identifier must remain adversarial-review"

jq -e --arg version "$VERSION" '
    .plugin_version == $version and
    .host_compatibility.product == "Codex" and
    (.host_compatibility.minimum_cli_version | test("^[0-9]+\\.[0-9]+\\.[0-9]+$")) and
    .host_compatibility.plugin_api == "experimental" and
    .host_compatibility.platforms == ["Linux", "macOS", "Windows via WSL"] and
    .cli_result_schema == 1 and
    .skill_workflow == "1" and
    .installation_layout == "1"
' "$COMPATIBILITY" >/dev/null || fail "host compatibility or versioned contract set is invalid"

jq -e '
    .name == "adversarial-review-local" and
    any(.plugins[];
        .name == "adversarial-review" and
        .source == {"source":"local","path":"./plugins/adversarial-review"})
' "$MARKETPLACE" >/dev/null || fail "marketplace does not expose the stable Plugin identifier"

while IFS= read -r path; do
    [[ "$path" == ./* ]] || fail "manifest path must be relative to the Plugin root: $path"
    [[ "$path" != *../* ]] || fail "manifest path escapes the Plugin root: $path"
done < <(jq -r '[.skills, .apps, .mcpServers, .hooks] | .[]? | strings' "$MANIFEST")

RELEASE_NOTES="$REPO_ROOT/docs/releases/$VERSION.md"
[[ -f "$RELEASE_NOTES" ]] || fail "release notes are missing for Plugin $VERSION"
for field in \
    "Plugin version: $VERSION" \
    "Result schema: $(jq -r '.cli_result_schema' "$COMPATIBILITY")" \
    "Supported platforms:" \
    "Host compatibility:" \
    "## External prerequisites" \
    "## Migration and compatibility" \
    "## Known limitations"; do
    grep -Fq "$field" "$RELEASE_NOTES" || fail "release notes are missing: $field"
done

echo "ok - Plugin $VERSION release metadata is valid"

if [[ "$METADATA_ONLY" == true ]]; then
    exit 0
fi

[[ "$REPO_ROOT" == "$(cd "$SCRIPT_DIR/.." && pwd)" ]] ||
    fail "full acceptance must run from the repository candidate"
command -v codex >/dev/null 2>&1 || fail "Codex CLI is required for full release acceptance"

REQUIRE_CODEX_PLUGIN_TESTS=true "$REPO_ROOT/tests/test_plugin_package.sh"
REQUIRE_CODEX_PLUGIN_TESTS=true "$REPO_ROOT/tests/test_plugin_marketplace_lifecycle.sh"

echo "ok - Plugin $VERSION passed deterministic release acceptance (no paid model calls)"
