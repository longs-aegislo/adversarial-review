#!/usr/bin/env bash

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GATE="$REPO_ROOT/scripts/validate-plugin-release.sh"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

fail() {
    echo "not ok - $1" >&2
    exit 1
}

[[ -x "$GATE" ]] || fail "release gate entry point is missing or not executable"

"$GATE" --metadata-only > "$TEST_ROOT/valid.out" || {
    cat "$TEST_ROOT/valid.out" >&2
    fail "repository candidate did not pass release metadata validation"
}
grep -q "release metadata is valid" "$TEST_ROOT/valid.out" ||
    fail "metadata validation did not report success"

FIXTURE_ROOT="$TEST_ROOT/repository"
mkdir -p "$FIXTURE_ROOT/plugins/adversarial-review/.codex-plugin" \
    "$FIXTURE_ROOT/.agents/plugins" "$FIXTURE_ROOT/docs/releases"
cp "$REPO_ROOT/plugins/adversarial-review/.codex-plugin/plugin.json" \
    "$FIXTURE_ROOT/plugins/adversarial-review/.codex-plugin/plugin.json"
cp "$REPO_ROOT/plugins/adversarial-review/compatibility.json" \
    "$FIXTURE_ROOT/plugins/adversarial-review/compatibility.json"
cp "$REPO_ROOT/.agents/plugins/marketplace.json" \
    "$FIXTURE_ROOT/.agents/plugins/marketplace.json"
cp "$REPO_ROOT/docs/releases/0.3.0.md" "$FIXTURE_ROOT/docs/releases/0.3.0.md"

expect_metadata_failure() {
    local expected="$1"
    local output="$2"
    set +e
    PLUGIN_RELEASE_ROOT="$FIXTURE_ROOT" "$GATE" --metadata-only > "$output" 2>&1
    local status=$?
    set -e
    [[ $status -ne 0 ]] || fail "invalid release metadata unexpectedly passed: $expected"
    grep -q "$expected" "$output" || {
        cat "$output" >&2
        fail "invalid release metadata did not explain: $expected"
    }
}

jq '.version = "release-candidate"' \
    "$FIXTURE_ROOT/plugins/adversarial-review/.codex-plugin/plugin.json" \
    > "$TEST_ROOT/invalid-manifest.json"
mv "$TEST_ROOT/invalid-manifest.json" \
    "$FIXTURE_ROOT/plugins/adversarial-review/.codex-plugin/plugin.json"
expect_metadata_failure "semantic version" "$TEST_ROOT/semver.out"

cp "$REPO_ROOT/plugins/adversarial-review/.codex-plugin/plugin.json" \
    "$FIXTURE_ROOT/plugins/adversarial-review/.codex-plugin/plugin.json"
jq 'del(.host_compatibility)' "$FIXTURE_ROOT/plugins/adversarial-review/compatibility.json" \
    > "$TEST_ROOT/no-host.json"
mv "$TEST_ROOT/no-host.json" "$FIXTURE_ROOT/plugins/adversarial-review/compatibility.json"
expect_metadata_failure "host compatibility" "$TEST_ROOT/host.out"

cp "$REPO_ROOT/plugins/adversarial-review/compatibility.json" \
    "$FIXTURE_ROOT/plugins/adversarial-review/compatibility.json"
sed -i '/^Result schema:/d' "$FIXTURE_ROOT/docs/releases/0.3.0.md"
expect_metadata_failure "Result schema" "$TEST_ROOT/release-notes.out"

echo "ok - release gate validates candidate identity, compatibility, and release-note contract"
