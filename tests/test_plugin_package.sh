#!/usr/bin/env bash

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MARKETPLACE="$REPO_ROOT/.agents/plugins/marketplace.json"
PLUGIN_ROOT="$REPO_ROOT/plugins/adversarial-review"
MANIFEST="$PLUGIN_ROOT/.codex-plugin/plugin.json"

fail() {
    echo "not ok - $1" >&2
    exit 1
}

[[ -f "$MARKETPLACE" ]] || fail "repository marketplace is missing"
[[ -f "$MANIFEST" ]] || fail "plugin manifest is missing"

jq -e '
    .name == "adversarial-review" and
    (.version | test("^[0-9]+\\.[0-9]+\\.[0-9]+$")) and
    (.description | type == "string" and length > 0) and
    .skills == "./skills/" and
    .interface.displayName == "Adversarial Review" and
    (.interface.shortDescription | type == "string" and length > 0) and
    (.interface.longDescription | contains("multi-agent adversarial review")) and
    (.interface.defaultPrompt | all(contains("multi-agent") and contains("apply-fixes"))) and
    (has("mcpServers") | not) and
    (has("apps") | not) and
    (has("hooks") | not)
' "$MANIFEST" >/dev/null || fail "plugin manifest does not satisfy the package contract"

jq -e '
    .name == "adversarial-review-local" and
    (.plugins | length == 1) and
    .plugins[0].name == "adversarial-review" and
    .plugins[0].source == {"source":"local","path":"./plugins/adversarial-review"} and
    .plugins[0].policy.installation == "AVAILABLE" and
    .plugins[0].policy.authentication == "ON_USE" and
    .plugins[0].policy.products == ["CODEX"]
' "$MARKETPLACE" >/dev/null || fail "marketplace entry does not satisfy the local install contract"

for required in \
    skills/adversarial-review/SKILL.md \
    skills/adversarial-review/agents/openai.yaml \
    skills/adversarial-review/scripts/run-review.sh \
    runtime/adversarial_review.sh \
    runtime/lib/circuit_breaker.sh \
    runtime/lib/date_utils.sh \
    runtime/lib/response_analyzer.sh \
    runtime/prompts/initial_review.md \
    runtime/prompts/cross_review.md \
    runtime/prompts/meta_review.md \
    runtime/prompts/synthesis.md; do
    [[ -f "$PLUGIN_ROOT/$required" ]] || fail "plugin is missing $required"
done

cmp "$REPO_ROOT/adversarial_review.sh" "$PLUGIN_ROOT/runtime/adversarial_review.sh" >/dev/null ||
    fail "bundled CLI runtime has drifted from the repository CLI"
for source in "$REPO_ROOT"/lib/*.sh "$REPO_ROOT"/prompts/*.md; do
    case "$source" in
        "$REPO_ROOT"/lib/*) bundled="$PLUGIN_ROOT/runtime/lib/${source##*/}" ;;
        *) bundled="$PLUGIN_ROOT/runtime/prompts/${source##*/}" ;;
    esac
    cmp "$source" "$bundled" >/dev/null || fail "bundled runtime file has drifted: ${source##*/}"
done

if find "$PLUGIN_ROOT" -type l -print -quit | grep -q .; then
    fail "plugin package must not depend on symlinks outside its root"
fi

while IFS= read -r path; do
    [[ "$path" == ./* ]] || fail "manifest path must be plugin-relative: $path"
    [[ "$path" != *../* ]] || fail "manifest path escapes plugin root: $path"
done < <(jq -r '[.skills, .apps, .mcpServers, .hooks] | .[]? | strings' "$MANIFEST")

echo "ok - plugin manifest, contents, and path boundaries are valid"

if ! command -v codex >/dev/null 2>&1; then
    if [[ "${REQUIRE_CODEX_PLUGIN_TESTS:-false}" == "true" ]]; then
        fail "codex CLI is required when REQUIRE_CODEX_PLUGIN_TESTS=true"
    fi
    echo "ok - Codex CLI integration skipped (codex unavailable) # SKIP"
    exit 0
fi

PROFILE_ROOT="$(mktemp -d)"
trap 'rm -rf "$PROFILE_ROOT"' EXIT
MARKETPLACE_SOURCE="$PROFILE_ROOT/marketplace-source"
mkdir -p "$PROFILE_ROOT/home" "$PROFILE_ROOT/codex" "$MARKETPLACE_SOURCE/.agents/plugins"
cp "$MARKETPLACE" "$MARKETPLACE_SOURCE/.agents/plugins/marketplace.json"
cp -R "$REPO_ROOT/plugins" "$MARKETPLACE_SOURCE/plugins"

run_codex() {
    HOME="$PROFILE_ROOT/home" CODEX_HOME="$PROFILE_ROOT/codex" codex "$@"
}

run_codex plugin marketplace add "$MARKETPLACE_SOURCE" --json > "$PROFILE_ROOT/marketplace-add.json" ||
    fail "Codex could not register the repository marketplace"

AVAILABLE_JSON="$(run_codex plugin list --available --json)" ||
    fail "Codex could not list repository marketplace plugins"
jq -e '
    any(.available[];
        .name == "adversarial-review" and
        .marketplaceName == "adversarial-review-local" and
        .installed == false)
' <<< "$AVAILABLE_JSON" >/dev/null || fail "adversarial-review is not available from the local marketplace"

run_codex plugin add adversarial-review@adversarial-review-local --json > "$PROFILE_ROOT/plugin-add.json" ||
    fail "Codex could not install adversarial-review"

INSTALLED_JSON="$(run_codex plugin list --json)" || fail "Codex could not list installed plugins"
INSTALLED_ROOT="$(jq -r '.installedPath // empty' "$PROFILE_ROOT/plugin-add.json")"
[[ -n "$INSTALLED_ROOT" && -d "$INSTALLED_ROOT" ]] ||
    fail "installed adversarial-review path was not reported"
jq -e '
    any(.installed[];
        .name == "adversarial-review" and
        .marketplaceName == "adversarial-review-local" and
        .installed == true and .enabled == true)
' <<< "$INSTALLED_JSON" >/dev/null || fail "installed adversarial-review is not enabled"

mv "$MARKETPLACE_SOURCE" "$PROFILE_ROOT/source-unavailable"

INSTALLED_SKILL="$INSTALLED_ROOT/skills/adversarial-review/SKILL.md"
[[ -f "$INSTALLED_SKILL" ]] || fail "installed Plugin does not expose the adversarial-review Skill"
[[ "$(find "$INSTALLED_ROOT/skills" -name SKILL.md -type f | wc -l | tr -d ' ')" == "1" ]] ||
    fail "installed Plugin must expose exactly one Skill"

echo "ok - clean Codex profile lists, installs, and discovers the bundled Skill"

TARGET_REPO="$PROFILE_ROOT/target"
FAKE_BIN="$PROFILE_ROOT/fake-bin"
mkdir -p "$TARGET_REPO" "$FAKE_BIN"
git -C "$TARGET_REPO" init -q
git -C "$TARGET_REPO" config user.name "Plugin E2E"
git -C "$TARGET_REPO" config user.email "plugin-e2e@example.com"
printf '%s\n' 'committed' > "$TARGET_REPO/app.sh"
git -C "$TARGET_REPO" add app.sh
git -C "$TARGET_REPO" commit -qm initial
printf '%s\n' 'review me' >> "$TARGET_REPO/app.sh"

for utility in awk basename bash cat cmp cut dirname find git grep head jq mkdir mktemp mv rm sed sort tail timeout tr wc; do
    ln -s "$(command -v "$utility")" "$FAKE_BIN/$utility"
done
ln -s "$(type -P true)" "$FAKE_BIN/true"
cp "$REPO_ROOT/tests/fixtures/plugin-backends/claude" "$FAKE_BIN/claude"
cp "$REPO_ROOT/tests/fixtures/plugin-backends/codex" "$FAKE_BIN/codex"
chmod +x "$FAKE_BIN/claude" "$FAKE_BIN/codex"
printf '%s\n' '#!/usr/bin/env bash' 'exit 99' > "$FAKE_BIN/adversarial_review.sh"
chmod +x "$FAKE_BIN/adversarial_review.sh"

TARGET_HASH_BEFORE="$(git -C "$TARGET_REPO" hash-object app.sh)"
set +e
(
    cd "$TARGET_REPO"
    PATH="$FAKE_BIN:$PATH" "$INSTALLED_ROOT/skills/adversarial-review/scripts/run-review.sh"
) > "$PROFILE_ROOT/review.out" 2>&1
REVIEW_STATUS=$?
set -e

[[ $REVIEW_STATUS -eq 10 ]] || {
    cat "$PROFILE_ROOT/review.out" >&2
    fail "installed Skill adapter did not preserve review-only findings status"
}
grep -q "Review result: Findings remaining" "$PROFILE_ROOT/review.out" ||
    fail "installed Skill adapter did not parse the bundled runtime result"
[[ "$(git -C "$TARGET_REPO" hash-object app.sh)" == "$TARGET_HASH_BEFORE" ]] ||
    fail "review-only Plugin run modified the Target Repo"

echo "ok - installed Skill launches bundled runtime through fake backends in review-only mode"
