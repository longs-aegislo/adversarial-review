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
    "$FIXTURE_ROOT/plugins/adversarial-review/assets" \
    "$FIXTURE_ROOT/.agents/plugins" "$FIXTURE_ROOT/docs/releases"
cp "$REPO_ROOT/plugins/adversarial-review/.codex-plugin/plugin.json" \
    "$FIXTURE_ROOT/plugins/adversarial-review/.codex-plugin/plugin.json"
cp "$REPO_ROOT/plugins/adversarial-review/compatibility.json" \
    "$FIXTURE_ROOT/plugins/adversarial-review/compatibility.json"
cp "$REPO_ROOT/plugins/adversarial-review/assets/composer-icon.png" \
    "$FIXTURE_ROOT/plugins/adversarial-review/assets/composer-icon.png"
cp "$REPO_ROOT/plugins/adversarial-review/assets/logo.png" \
    "$FIXTURE_ROOT/plugins/adversarial-review/assets/logo.png"
cp "$REPO_ROOT/.agents/plugins/marketplace.json" \
    "$FIXTURE_ROOT/.agents/plugins/marketplace.json"
CANDIDATE_VERSION="$(jq -r '.version' \
    "$FIXTURE_ROOT/plugins/adversarial-review/.codex-plugin/plugin.json")"
RELEASE_NOTES="docs/releases/$CANDIDATE_VERSION.md"
cp "$REPO_ROOT/$RELEASE_NOTES" "$FIXTURE_ROOT/$RELEASE_NOTES"

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

mv "$FIXTURE_ROOT/plugins/adversarial-review/assets/logo.png" \
    "$TEST_ROOT/missing-logo.png"
expect_metadata_failure "logo asset is missing" "$TEST_ROOT/missing-logo.out"
mv "$TEST_ROOT/missing-logo.png" \
    "$FIXTURE_ROOT/plugins/adversarial-review/assets/logo.png"

mv "$FIXTURE_ROOT/plugins/adversarial-review/assets/composer-icon.png" \
    "$TEST_ROOT/missing-composer-icon.png"
expect_metadata_failure "composerIcon asset is missing" "$TEST_ROOT/missing-composer.out"
mv "$TEST_ROOT/missing-composer-icon.png" \
    "$FIXTURE_ROOT/plugins/adversarial-review/assets/composer-icon.png"

mv "$FIXTURE_ROOT/plugins/adversarial-review/assets/logo.png" \
    "$TEST_ROOT/valid-logo.png"
cp "$FIXTURE_ROOT/plugins/adversarial-review/compatibility.json" \
    "$FIXTURE_ROOT/plugins/adversarial-review/assets/logo.png"
expect_metadata_failure "logo must be a PNG image" "$TEST_ROOT/non-png-logo.out"
mv "$TEST_ROOT/valid-logo.png" \
    "$FIXTURE_ROOT/plugins/adversarial-review/assets/logo.png"

mv "$FIXTURE_ROOT/plugins/adversarial-review/assets/composer-icon.png" \
    "$TEST_ROOT/valid-composer-icon.png"
cp "$TEST_ROOT/valid-composer-icon.png" \
    "$FIXTURE_ROOT/plugins/adversarial-review/assets/composer-icon.png"
# PNG IHDR height occupies bytes 20-23. Change it to 1; `file` reads the
# dimensions without requiring a valid image-data CRC, which keeps this
# negative fixture dependency-free and portable.
printf '\x00\x00\x00\x01' | dd \
    of="$FIXTURE_ROOT/plugins/adversarial-review/assets/composer-icon.png" \
    bs=1 seek=20 conv=notrunc 2>/dev/null
expect_metadata_failure "composerIcon must be square" "$TEST_ROOT/non-square-composer.out"
mv "$TEST_ROOT/valid-composer-icon.png" \
    "$FIXTURE_ROOT/plugins/adversarial-review/assets/composer-icon.png"

jq '.version = "0.3.0-rc.1+fixture"' \
    "$FIXTURE_ROOT/plugins/adversarial-review/.codex-plugin/plugin.json" \
    > "$TEST_ROOT/prerelease-manifest.json"
mv "$TEST_ROOT/prerelease-manifest.json" \
    "$FIXTURE_ROOT/plugins/adversarial-review/.codex-plugin/plugin.json"
jq '.plugin_version = "0.3.0-rc.1+fixture"' \
    "$FIXTURE_ROOT/plugins/adversarial-review/compatibility.json" \
    > "$TEST_ROOT/prerelease-compatibility.json"
mv "$TEST_ROOT/prerelease-compatibility.json" \
    "$FIXTURE_ROOT/plugins/adversarial-review/compatibility.json"
sed 's/^Plugin version: .*/Plugin version: 0.3.0-rc.1+fixture/' \
    "$FIXTURE_ROOT/$RELEASE_NOTES" > \
    "$FIXTURE_ROOT/docs/releases/0.3.0-rc.1+fixture.md"
PLUGIN_RELEASE_ROOT="$FIXTURE_ROOT" "$GATE" --metadata-only > "$TEST_ROOT/prerelease.out" || {
    cat "$TEST_ROOT/prerelease.out" >&2
    fail "valid SemVer prerelease/build candidate did not pass"
}
rm "$FIXTURE_ROOT/docs/releases/0.3.0-rc.1+fixture.md"
cp "$REPO_ROOT/plugins/adversarial-review/compatibility.json" \
    "$FIXTURE_ROOT/plugins/adversarial-review/compatibility.json"
cp "$REPO_ROOT/plugins/adversarial-review/.codex-plugin/plugin.json" \
    "$FIXTURE_ROOT/plugins/adversarial-review/.codex-plugin/plugin.json"

jq '.version = "release-candidate"' \
    "$FIXTURE_ROOT/plugins/adversarial-review/.codex-plugin/plugin.json" \
    > "$TEST_ROOT/invalid-manifest.json"
mv "$TEST_ROOT/invalid-manifest.json" \
    "$FIXTURE_ROOT/plugins/adversarial-review/.codex-plugin/plugin.json"
expect_metadata_failure "semantic version" "$TEST_ROOT/semver.out"

cp "$REPO_ROOT/plugins/adversarial-review/.codex-plugin/plugin.json" \
    "$FIXTURE_ROOT/plugins/adversarial-review/.codex-plugin/plugin.json"
jq '.skills = "./.."' \
    "$FIXTURE_ROOT/plugins/adversarial-review/.codex-plugin/plugin.json" \
    > "$TEST_ROOT/escaping-manifest.json"
mv "$TEST_ROOT/escaping-manifest.json" \
    "$FIXTURE_ROOT/plugins/adversarial-review/.codex-plugin/plugin.json"
expect_metadata_failure "escapes the Plugin root" "$TEST_ROOT/escape.out"

cp "$REPO_ROOT/plugins/adversarial-review/.codex-plugin/plugin.json" \
    "$FIXTURE_ROOT/plugins/adversarial-review/.codex-plugin/plugin.json"
jq '.apps = [{"path":"./apps/safe"}, {"path":"../evil"}]' \
    "$FIXTURE_ROOT/plugins/adversarial-review/.codex-plugin/plugin.json" \
    > "$TEST_ROOT/nested-escaping-manifest.json"
mv "$TEST_ROOT/nested-escaping-manifest.json" \
    "$FIXTURE_ROOT/plugins/adversarial-review/.codex-plugin/plugin.json"
expect_metadata_failure "escapes the Plugin root" "$TEST_ROOT/nested-escape.out"

cp "$REPO_ROOT/plugins/adversarial-review/.codex-plugin/plugin.json" \
    "$FIXTURE_ROOT/plugins/adversarial-review/.codex-plugin/plugin.json"
jq 'del(.host_compatibility)' "$FIXTURE_ROOT/plugins/adversarial-review/compatibility.json" \
    > "$TEST_ROOT/no-host.json"
mv "$TEST_ROOT/no-host.json" "$FIXTURE_ROOT/plugins/adversarial-review/compatibility.json"
expect_metadata_failure "host compatibility" "$TEST_ROOT/host.out"

cp "$REPO_ROOT/plugins/adversarial-review/compatibility.json" \
    "$FIXTURE_ROOT/plugins/adversarial-review/compatibility.json"
sed -i '/^Result schema:/d' "$FIXTURE_ROOT/$RELEASE_NOTES"
expect_metadata_failure "Result schema" "$TEST_ROOT/release-notes.out"

cp "$REPO_ROOT/$RELEASE_NOTES" "$FIXTURE_ROOT/$RELEASE_NOTES"
sed -i '/^## Known limitations$/,/^## /{/^## Known limitations$/!{/^## /!d;}}' \
    "$FIXTURE_ROOT/$RELEASE_NOTES"
expect_metadata_failure "section is empty: ## Known limitations" "$TEST_ROOT/empty-section.out"

OLD_CODEX="$TEST_ROOT/old-codex"
printf '%s\n' '#!/usr/bin/env bash' 'echo "codex-cli 0.145.0"' > "$OLD_CODEX"
chmod +x "$OLD_CODEX"
set +e
PLUGIN_RELEASE_CODEX="$OLD_CODEX" "$GATE" > "$TEST_ROOT/old-host.out" 2>&1
OLD_HOST_STATUS=$?
set -e
[[ $OLD_HOST_STATUS -ne 0 ]] || fail "incompatible Codex host unexpectedly passed"
grep -q "requires Codex CLI 0.146.0 or later" "$TEST_ROOT/old-host.out" || {
    cat "$TEST_ROOT/old-host.out" >&2
    fail "incompatible Codex host failure was not actionable"
}

BARE_CODEX="$TEST_ROOT/bare-codex"
printf '%s\n' '#!/usr/bin/env bash' 'echo "0.09.0"' > "$BARE_CODEX"
chmod +x "$BARE_CODEX"
set +e
PLUGIN_RELEASE_CODEX="$BARE_CODEX" "$GATE" > "$TEST_ROOT/bare-host.out" 2>&1
BARE_HOST_STATUS=$?
set -e
[[ $BARE_HOST_STATUS -ne 0 ]] || fail "incompatible bare Codex version unexpectedly passed"
grep -q "requires Codex CLI 0.146.0 or later (found 0.09.0)" "$TEST_ROOT/bare-host.out" || {
    cat "$TEST_ROOT/bare-host.out" >&2
    fail "bare Codex version or decimal comparison was not handled cleanly"
}

echo "ok - release gate validates candidate identity, compatibility, and release-note contract"
