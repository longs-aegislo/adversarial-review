#!/usr/bin/env bash

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLUGIN_NAME="adversarial-review"
MARKETPLACE_NAME="adversarial-review-local"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

fail() {
    echo "not ok - $1" >&2
    exit 1
}

if ! command -v codex >/dev/null 2>&1; then
    if [[ "${REQUIRE_CODEX_PLUGIN_TESTS:-false}" == "true" ]]; then
        fail "codex CLI is required when REQUIRE_CODEX_PLUGIN_TESTS=true"
    fi
    echo "ok - Git marketplace lifecycle skipped (codex unavailable) # SKIP"
    exit 0
fi

run_codex() {
    local profile="$1"
    shift
    HOME="$profile/home" CODEX_HOME="$profile/codex" codex "$@"
}

assert_listed_version() {
    local profile="$1"
    local version="$2"
    local installed="$3"
    local listing
    listing="$(run_codex "$profile" plugin list --available --json)" ||
        fail "Codex could not list Plugin version $version"
    jq -e --arg version "$version" --argjson installed "$installed" '
        any((.installed + .available)[];
            .name == "adversarial-review" and
            .marketplaceName == "adversarial-review-local" and
            .version == $version and
            .installed == $installed and
            (.enabled == $installed))
    ' <<< "$listing" >/dev/null || fail "listed Plugin is not version $version with expected state"
}

install_plugin() {
    local profile="$1"
    local output="$2"
    run_codex "$profile" plugin add "$PLUGIN_NAME@$MARKETPLACE_NAME" --json > "$output" ||
        fail "Codex could not install $PLUGIN_NAME"
    jq -er '.installedPath' "$output"
}

SOURCE_WORK="$TEST_ROOT/source-work"
SOURCE_BARE="$TEST_ROOT/source.git"
FAKE_SSH="$TEST_ROOT/fixture-ssh"
mkdir -p "$SOURCE_WORK/.agents/plugins"
cp "$REPO_ROOT/.agents/plugins/marketplace.json" "$SOURCE_WORK/.agents/plugins/marketplace.json"
cp -R "$REPO_ROOT/plugins" "$SOURCE_WORK/plugins"

# Publish a deliberately older, internally paired package with a file that must
# disappear when the candidate package replaces it.
jq '.version = "0.2.0"' \
    "$SOURCE_WORK/plugins/$PLUGIN_NAME/.codex-plugin/plugin.json" > "$TEST_ROOT/old-manifest.json"
mv "$TEST_ROOT/old-manifest.json" "$SOURCE_WORK/plugins/$PLUGIN_NAME/.codex-plugin/plugin.json"
jq '.plugin_version = "0.2.0"' \
    "$SOURCE_WORK/plugins/$PLUGIN_NAME/compatibility.json" > "$TEST_ROOT/old-compatibility.json"
mv "$TEST_ROOT/old-compatibility.json" "$SOURCE_WORK/plugins/$PLUGIN_NAME/compatibility.json"
printf '%s\n' 'old package residue' > "$SOURCE_WORK/plugins/$PLUGIN_NAME/removed-in-0.3.txt"
printf '%s\n' '# fixture-old-skill' >> \
    "$SOURCE_WORK/plugins/$PLUGIN_NAME/skills/adversarial-review/SKILL.md"
printf '%s\n' '# fixture-old-runtime' >> \
    "$SOURCE_WORK/plugins/$PLUGIN_NAME/runtime/adversarial_review.sh"
sed -i 's|^STATE_ROOT=.*|STATE_ROOT="${AR_STATE_ROOT:-$SCRIPT_DIR/state}"|' \
    "$SOURCE_WORK/plugins/$PLUGIN_NAME/runtime/adversarial_review.sh"

git init -q --bare "$SOURCE_BARE"
git -C "$SOURCE_WORK" init -q
git -C "$SOURCE_WORK" config user.name "Plugin Lifecycle"
git -C "$SOURCE_WORK" config user.email "plugin-lifecycle@example.com"
git -C "$SOURCE_WORK" add .
git -C "$SOURCE_WORK" commit -qm "fixture: Plugin 0.2.0"
git -C "$SOURCE_WORK" branch -M candidate
git -C "$SOURCE_WORK" tag v0.2.0
git -C "$SOURCE_WORK" remote add origin "$SOURCE_BARE"
git -C "$SOURCE_WORK" push -q -u origin candidate
git -C "$SOURCE_WORK" push -q origin v0.2.0

printf '%s\n' \
    '#!/usr/bin/env bash' \
    '[[ "${FIXTURE_GIT_FETCH_FAIL:-false}" == "true" ]] && exit 86' \
    'exec git-upload-pack "$FIXTURE_GIT_REMOTE"' > "$FAKE_SSH"
chmod +x "$FAKE_SSH"
export FIXTURE_GIT_REMOTE="$SOURCE_BARE"
export GIT_SSH_COMMAND="$FAKE_SSH"
GIT_SOURCE="ssh://fixture/adversarial-review.git"

PINNED_PROFILE="$TEST_ROOT/pinned-profile"
mkdir -p "$PINNED_PROFILE/home" "$PINNED_PROFILE/codex"
run_codex "$PINNED_PROFILE" plugin marketplace add "$GIT_SOURCE" --ref v0.2.0 --json \
    > "$TEST_ROOT/pinned-marketplace.json" || fail "Codex could not add a ref-pinned Git marketplace"
jq -e --arg root "$SOURCE_BARE" '
    .marketplaceName == "adversarial-review-local" and (.installedRoot | type == "string")
' "$TEST_ROOT/pinned-marketplace.json" >/dev/null || fail "pinned marketplace identity was not reported"
assert_listed_version "$PINNED_PROFILE" "0.2.0" false
PINNED_ROOT="$(install_plugin "$PINNED_PROFILE" "$TEST_ROOT/pinned-install.json")"
assert_listed_version "$PINNED_PROFILE" "0.2.0" true
[[ -f "$PINNED_ROOT/removed-in-0.3.txt" ]] || fail "pinned install did not use the expected old fixture"

UPGRADE_PROFILE="$TEST_ROOT/upgrade-profile"
mkdir -p "$UPGRADE_PROFILE/home" "$UPGRADE_PROFILE/codex"
run_codex "$UPGRADE_PROFILE" plugin marketplace add "$GIT_SOURCE" --ref candidate --json \
    > "$TEST_ROOT/upgrade-marketplace.json" || fail "Codex could not add the upgrade Git marketplace"
OLD_INSTALLED_ROOT="$(install_plugin "$UPGRADE_PROFILE" "$TEST_ROOT/old-install.json")"
assert_listed_version "$UPGRADE_PROFILE" "0.2.0" true
grep -q 'fixture-old-skill' "$OLD_INSTALLED_ROOT/skills/adversarial-review/SKILL.md" ||
    fail "old fixture Skill marker is missing"
grep -q 'fixture-old-runtime' "$OLD_INSTALLED_ROOT/runtime/adversarial_review.sh" ||
    fail "old fixture runtime marker is missing"

TARGET_REPO="$TEST_ROOT/target-repo"
mkdir -p "$TARGET_REPO"
OLD_STATUS="$(HOME="$UPGRADE_PROFILE/home" \
    "$OLD_INSTALLED_ROOT/runtime/adversarial_review.sh" claude codex "$TARGET_REPO" --status)"
LEGACY_STATE_ROOT="$(sed -n 's/.*State dir: //p' <<< "$OLD_STATUS" | tail -1)"
[[ -n "$LEGACY_STATE_ROOT" && "$LEGACY_STATE_ROOT" == "$OLD_INSTALLED_ROOT"/* ]] ||
    fail "old fixture did not reproduce the versioned Plugin state layout"
mkdir -p "$LEGACY_STATE_ROOT/artifacts"
printf '%s\n' '{"target_dir":"fixture","history":[],"iteration":2,"status":"in_progress"}' \
    > "$LEGACY_STATE_ROOT/tracking.json"
printf '%s\n' 'review artifact before Plugin upgrade' > "$LEGACY_STATE_ROOT/artifacts/iter2_1_codex_review.md"
TRACKING_HASH_BEFORE="$(shasum "$LEGACY_STATE_ROOT/tracking.json" | cut -d ' ' -f 1)"
ARTIFACT_HASH_BEFORE="$(shasum "$LEGACY_STATE_ROOT/artifacts/iter2_1_codex_review.md" | cut -d ' ' -f 1)"
LEGACY_STATE_PARENT="${LEGACY_STATE_ROOT%/*}"
mkdir -p "$LEGACY_STATE_PARENT/z-conflict/artifacts"
printf '%s\n' 'second legacy state' > "$LEGACY_STATE_PARENT/z-conflict/tracking.json"

rm -rf "$SOURCE_WORK/plugins"
cp -R "$REPO_ROOT/plugins" "$SOURCE_WORK/plugins"
git -C "$SOURCE_WORK" add -A
git -C "$SOURCE_WORK" commit -qm "fixture: Plugin 0.3.0 candidate"
git -C "$SOURCE_WORK" push -q origin candidate

MIGRATED_STATE_ROOT="$TARGET_REPO/stable-review-state"
mkdir -p "$MIGRATED_STATE_ROOT/z-conflict"
set +e
HOME="$UPGRADE_PROFILE/home" CODEX_HOME="$UPGRADE_PROFILE/codex" \
    AR_STATE_ROOT="$MIGRATED_STATE_ROOT" \
    "$REPO_ROOT/scripts/upgrade-plugin.sh" "$MARKETPLACE_NAME" "$PLUGIN_NAME" \
    > "$TEST_ROOT/conflict-upgrade.out" 2>&1
CONFLICT_STATUS=$?
set -e
[[ $CONFLICT_STATUS -eq 73 ]] || fail "state migration conflict did not stop the upgrade"
[[ ! -e "$MIGRATED_STATE_ROOT/${LEGACY_STATE_ROOT##*/}" ]] ||
    fail "state migration copied some targets before detecting all conflicts"
assert_listed_version "$UPGRADE_PROFILE" "0.2.0" true
rm -rf "$MIGRATED_STATE_ROOT/z-conflict"

set +e
HOME="$UPGRADE_PROFILE/home" CODEX_HOME="$UPGRADE_PROFILE/codex" \
    AR_STATE_ROOT="$MIGRATED_STATE_ROOT" FIXTURE_GIT_FETCH_FAIL=true \
    "$REPO_ROOT/scripts/upgrade-plugin.sh" "$MARKETPLACE_NAME" "$PLUGIN_NAME" \
    > "$TEST_ROOT/fetch-failure.out" 2>&1
FETCH_FAILURE_STATUS=$?
set -e
[[ $FETCH_FAILURE_STATUS -ne 0 && $FETCH_FAILURE_STATUS -ne 73 ]] ||
    fail "simulated marketplace refresh failure returned an unexpected status"
[[ -f "$MIGRATED_STATE_ROOT/${LEGACY_STATE_ROOT##*/}/tracking.json" ]] ||
    fail "state was not migrated before the simulated marketplace failure"
assert_listed_version "$UPGRADE_PROFILE" "0.2.0" true

NEW_INSTALLED_ROOT="$(HOME="$UPGRADE_PROFILE/home" CODEX_HOME="$UPGRADE_PROFILE/codex" \
    AR_STATE_ROOT="$MIGRATED_STATE_ROOT" \
    "$REPO_ROOT/scripts/upgrade-plugin.sh" "$MARKETPLACE_NAME" "$PLUGIN_NAME")" ||
    fail "Plugin lifecycle upgrade command failed"
assert_listed_version "$UPGRADE_PROFILE" "0.3.0" true

[[ "$NEW_INSTALLED_ROOT" != "$OLD_INSTALLED_ROOT" ]] || fail "upgrade reused the old version directory"
[[ ! -e "$NEW_INSTALLED_ROOT/removed-in-0.3.txt" ]] || fail "upgrade mixed a stale file into the candidate package"
grep -q 'fixture-old-skill' "$NEW_INSTALLED_ROOT/skills/adversarial-review/SKILL.md" &&
    fail "upgrade retained the old Skill"
grep -q 'fixture-old-runtime' "$NEW_INSTALLED_ROOT/runtime/adversarial_review.sh" &&
    fail "upgrade retained the old runtime"
cmp "$REPO_ROOT/plugins/$PLUGIN_NAME/skills/adversarial-review/SKILL.md" \
    "$NEW_INSTALLED_ROOT/skills/adversarial-review/SKILL.md" >/dev/null ||
    fail "upgraded Skill does not match the candidate package"
cmp "$REPO_ROOT/plugins/$PLUGIN_NAME/runtime/adversarial_review.sh" \
    "$NEW_INSTALLED_ROOT/runtime/adversarial_review.sh" >/dev/null ||
    fail "upgraded runtime does not match the candidate package"
jq -e --arg version "0.3.0" '
    .plugin_version == $version and .cli_result_schema == 1 and
    .skill_workflow == "1" and .installation_layout == "1"
' "$NEW_INSTALLED_ROOT/compatibility.json" >/dev/null ||
    fail "upgraded package does not expose the candidate compatibility contract"

NEW_STATUS="$(HOME="$UPGRADE_PROFILE/home" AR_STATE_ROOT="$MIGRATED_STATE_ROOT" \
    "$NEW_INSTALLED_ROOT/runtime/adversarial_review.sh" claude codex "$TARGET_REPO" --status)"
NEW_STATE_ROOT="$(sed -n 's/.*State dir: //p' <<< "$NEW_STATUS" | tail -1)"
[[ "$NEW_STATE_ROOT" != "$LEGACY_STATE_ROOT" && "$NEW_STATE_ROOT" != "$NEW_INSTALLED_ROOT"/* ]] ||
    fail "upgraded runtime did not resolve a stable state directory"
[[ "$NEW_STATE_ROOT" == "$MIGRATED_STATE_ROOT"/* ]] ||
    fail "upgrade did not honor the explicit AR_STATE_ROOT"
[[ "$(shasum "$NEW_STATE_ROOT/tracking.json" | cut -d ' ' -f 1)" == "$TRACKING_HASH_BEFORE" ]] ||
    fail "Plugin upgrade changed Target Repo review state"
[[ "$(shasum "$NEW_STATE_ROOT/artifacts/iter2_1_codex_review.md" | cut -d ' ' -f 1)" == "$ARTIFACT_HASH_BEFORE" ]] ||
    fail "Plugin upgrade changed a Target Repo Artifact"
grep -q '"iteration":2' "$NEW_STATE_ROOT/tracking.json" ||
    fail "upgraded runtime did not preserve old tracking state"
grep -q 'review artifact before Plugin upgrade' \
    "$NEW_STATE_ROOT/artifacts/iter2_1_codex_review.md" ||
    fail "upgraded runtime did not preserve the old Artifact"
grep -q 'iter2_1_codex_review.md' <<< "$NEW_STATUS" ||
    fail "upgraded runtime cannot list the pre-upgrade Artifact"

echo "ok - local and Git marketplace lifecycle preserves version pairing and Target Repo state"
