#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${PLUGIN_RELEASE_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
PLUGIN_ROOT="$REPO_ROOT/plugins/adversarial-review"
MANIFEST="$PLUGIN_ROOT/.codex-plugin/plugin.json"
COMPATIBILITY="$PLUGIN_ROOT/compatibility.json"
MARKETPLACE="$REPO_ROOT/.agents/plugins/marketplace.json"
METADATA_ONLY=false
SEMVER_PATTERN='^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?(\+[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?$'

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

section_has_content() {
    local heading="$1"
    awk -v heading="$heading" '
        $0 == heading { inside = 1; next }
        inside && /^## / { exit }
        inside && $0 !~ /^[[:space:]]*$/ { found = 1 }
        END { exit(found ? 0 : 1) }
    ' "$RELEASE_NOTES"
}

semver_core_at_least() {
    local actual="${1%%[-+]*}"
    local minimum="${2%%[-+]*}"
    local actual_major actual_minor actual_patch minimum_major minimum_minor minimum_patch
    IFS=. read -r actual_major actual_minor actual_patch <<< "$actual"
    IFS=. read -r minimum_major minimum_minor minimum_patch <<< "$minimum"
    actual_major=$((10#$actual_major))
    actual_minor=$((10#$actual_minor))
    actual_patch=$((10#$actual_patch))
    minimum_major=$((10#$minimum_major))
    minimum_minor=$((10#$minimum_minor))
    minimum_patch=$((10#$minimum_patch))
    (( actual_major > minimum_major )) ||
        (( actual_major == minimum_major && actual_minor > minimum_minor )) ||
        (( actual_major == minimum_major && actual_minor == minimum_minor && actual_patch >= minimum_patch ))
}

case "${1:-}" in
    "") ;;
    --metadata-only) METADATA_ONLY=true ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; fail "unknown argument: $1" ;;
esac
[[ $# -le 1 ]] || fail "too many arguments"

command -v jq >/dev/null 2>&1 || fail "jq is required"
command -v file >/dev/null 2>&1 || fail "file is required to validate Plugin image assets"
[[ -f "$MANIFEST" ]] || fail "Plugin manifest is missing"
[[ -f "$COMPATIBILITY" ]] || fail "compatibility metadata is missing"
[[ -f "$MARKETPLACE" ]] || fail "marketplace metadata is missing"

VERSION="$(jq -er '.version' "$MANIFEST")" || fail "manifest version is missing"
[[ "$VERSION" =~ $SEMVER_PATTERN ]] || fail "manifest version must be a semantic version"
[[ "$(jq -r '.name' "$MANIFEST")" == "adversarial-review" ]] ||
    fail "stable Plugin identifier must remain adversarial-review"
jq -e '
    .interface.composerIcon == "./assets/composer-icon.png" and
    .interface.logo == "./assets/logo.png"
' "$MANIFEST" >/dev/null || fail "Plugin icon metadata is missing or unstable"

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
    case "$path" in
        ../*|*/../*|*/..) fail "manifest path escapes the Plugin root: $path" ;;
    esac
    [[ "$path" == ./* ]] || fail "manifest path must be relative to the Plugin root: $path"
done < <(jq -r '
    [
        (.skills | .. | strings),
        ([.apps, .mcpServers, .hooks, .interface.composerIcon,
          .interface.logo, .interface.screenshots] | .[]? | .. | strings |
            select(
                startswith(".") or startswith("/") or
                test("^[A-Za-z]:[\\\\/]") or test("(^|/)\\.\\.(/|$)")
            ))
    ] | .[]
' "$MANIFEST")

for image_field in composerIcon logo; do
    image_path="$(jq -r --arg field "$image_field" '.interface[$field]' "$MANIFEST")"
    image_file="$PLUGIN_ROOT/${image_path#./}"
    [[ -f "$image_file" ]] || fail "Plugin $image_field asset is missing: $image_path"
    image_description="$(file -b "$image_file")"
    [[ "$image_description" =~ PNG\ image\ data,\ ([0-9]+)\ x\ ([0-9]+), ]] ||
        fail "Plugin $image_field must be a PNG image: $image_path"
    [[ "${BASH_REMATCH[1]}" == "${BASH_REMATCH[2]}" ]] ||
        fail "Plugin $image_field must be square: $image_path"
done

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
grep -Eq '^Supported platforms:[[:space:]]*[^[:space:]].*$' "$RELEASE_NOTES" ||
    fail "release notes have no Supported platforms content"
grep -Eq '^Host compatibility:[[:space:]]*[^[:space:]].*$' "$RELEASE_NOTES" ||
    fail "release notes have no Host compatibility content"
for heading in "## External prerequisites" "## Migration and compatibility" "## Known limitations"; do
    section_has_content "$heading" || fail "release notes section is empty: $heading"
done

echo "ok - Plugin $VERSION release metadata is valid"

if [[ "$METADATA_ONLY" == true ]]; then
    exit 0
fi

[[ "$REPO_ROOT" == "$(cd "$SCRIPT_DIR/.." && pwd)" ]] ||
    fail "full acceptance must run from the repository candidate"
CODEX_COMMAND="${PLUGIN_RELEASE_CODEX:-codex}"
command -v "$CODEX_COMMAND" >/dev/null 2>&1 || fail "Codex CLI is required for full release acceptance"
CODEX_VERSION_OUTPUT="$("$CODEX_COMMAND" --version 2>/dev/null)" || fail "Codex CLI version could not be read"
CODEX_VERSION="$(sed -nE 's/^[^0-9]*([0-9]+\.[0-9]+\.[0-9]+)([^0-9].*)?$/\1/p' <<< "$CODEX_VERSION_OUTPUT")"
[[ "$CODEX_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
    fail "Codex CLI returned an unrecognized version: $CODEX_VERSION_OUTPUT"
MINIMUM_CODEX_VERSION="$(jq -r '.host_compatibility.minimum_cli_version' "$COMPATIBILITY")"
semver_core_at_least "$CODEX_VERSION" "$MINIMUM_CODEX_VERSION" ||
    fail "host compatibility requires Codex CLI $MINIMUM_CODEX_VERSION or later (found $CODEX_VERSION)"

REQUIRE_CODEX_PLUGIN_TESTS=true "$REPO_ROOT/tests/test_plugin_package.sh"
REQUIRE_CODEX_PLUGIN_TESTS=true "$REPO_ROOT/tests/test_plugin_marketplace_lifecycle.sh"

echo "ok - Plugin $VERSION passed deterministic release acceptance (no paid model calls)"
