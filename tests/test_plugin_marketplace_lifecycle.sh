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

printf '%s\n' '#!/usr/bin/env bash' 'exec git-upload-pack "$FIXTURE_GIT_REMOTE"' > "$FAKE_SSH"
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
STATE_ROOT="$(sed -n 's/.*State dir: //p' <<< "$OLD_STATUS" | tail -1)"
[[ -n "$STATE_ROOT" && "$STATE_ROOT" != "$OLD_INSTALLED_ROOT"/* ]] ||
    fail "old runtime did not resolve stable state outside the versioned Plugin"
mkdir -p "$STATE_ROOT/artifacts"
printf '%s\n' '{"target_dir":"fixture","history":[],"iteration":2,"status":"in_progress"}' \
    > "$STATE_ROOT/tracking.json"
printf '%s\n' 'review artifact before Plugin upgrade' > "$STATE_ROOT/artifacts/iter2_1_codex_review.md"
STATE_HASH_BEFORE="$(find "$STATE_ROOT" -type f -exec shasum {} + | sort | shasum | cut -d ' ' -f 1)"

rm -rf "$SOURCE_WORK/plugins"
cp -R "$REPO_ROOT/plugins" "$SOURCE_WORK/plugins"
git -C "$SOURCE_WORK" add -A
git -C "$SOURCE_WORK" commit -qm "fixture: Plugin 0.3.0 candidate"
git -C "$SOURCE_WORK" push -q origin candidate

run_codex "$UPGRADE_PROFILE" plugin marketplace upgrade "$MARKETPLACE_NAME" --json \
    > "$TEST_ROOT/upgrade.json" || fail "Codex could not refresh the Git marketplace"
NEW_INSTALLED_ROOT="$(install_plugin "$UPGRADE_PROFILE" "$TEST_ROOT/new-install.json")"
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

STATE_HASH_AFTER="$(find "$STATE_ROOT" -type f -exec shasum {} + | sort | shasum | cut -d ' ' -f 1)"
[[ "$STATE_HASH_AFTER" == "$STATE_HASH_BEFORE" ]] || fail "Plugin upgrade changed Target Repo review state or Artifacts"
[[ -f "$STATE_ROOT/tracking.json" && -f "$STATE_ROOT/artifacts/iter2_1_codex_review.md" ]] ||
    fail "Target Repo review state or Artifacts became inaccessible after upgrade"
NEW_STATUS="$(HOME="$UPGRADE_PROFILE/home" \
    "$NEW_INSTALLED_ROOT/runtime/adversarial_review.sh" claude codex "$TARGET_REPO" --status)"
NEW_STATE_ROOT="$(sed -n 's/.*State dir: //p' <<< "$NEW_STATUS" | tail -1)"
[[ "$NEW_STATE_ROOT" == "$STATE_ROOT" ]] || fail "upgraded runtime cannot resolve the old state directory"
grep -q 'iter2_1_codex_review.md' <<< "$NEW_STATUS" ||
    fail "upgraded runtime cannot list the pre-upgrade Artifact"

echo "ok - local and Git marketplace lifecycle preserves version pairing and Target Repo state"
