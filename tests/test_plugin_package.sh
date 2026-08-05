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

for utility in awk basename bash cat cmp cut dirname find git grep head jq mkdir mktemp mv readlink rm sed shasum sort stat tail timeout tr wc; do
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

MISSING_JQ_BIN="$PROFILE_ROOT/missing-jq-bin"
mkdir -p "$MISSING_JQ_BIN"
ln -s "$(command -v bash)" "$MISSING_JQ_BIN/bash"
ln -s "$(command -v dirname)" "$MISSING_JQ_BIN/dirname"
set +e
(
    cd "$TARGET_REPO"
    PATH="$MISSING_JQ_BIN" "$INSTALLED_ROOT/skills/adversarial-review/scripts/run-review.sh"
) > "$PROFILE_ROOT/missing-jq.out" 2>&1
MISSING_JQ_STATUS=$?
set -e
[[ $MISSING_JQ_STATUS -eq 64 ]] || fail "missing jq preflight returned an unexpected status"
grep -q "missing dependency: jq" "$PROFILE_ROOT/missing-jq.out" ||
    fail "missing jq preflight was not actionable"

MISSING_CLAUDE_BIN="$PROFILE_ROOT/missing-claude-bin"
mkdir -p "$MISSING_CLAUDE_BIN"
for utility in awk basename bash cat cmp cut dirname find git grep head jq mkdir mktemp mv readlink rm sed shasum sort stat tail timeout tr wc; do
    ln -s "$(command -v "$utility")" "$MISSING_CLAUDE_BIN/$utility"
done
ln -s "$(type -P true)" "$MISSING_CLAUDE_BIN/true"
cp "$REPO_ROOT/tests/fixtures/plugin-backends/codex" "$MISSING_CLAUDE_BIN/codex"
chmod +x "$MISSING_CLAUDE_BIN/codex"
MISSING_BACKEND_LOG="$PROFILE_ROOT/missing-backend.log"
PREFLIGHT_PATH="$MISSING_CLAUDE_BIN:/usr/bin:/bin"
[[ -z "$(PATH="$PREFLIGHT_PATH" command -v claude 2>/dev/null || true)" ]] ||
    fail "test environment unexpectedly exposes Claude in the one-backend PATH"
set +e
(
    cd "$TARGET_REPO"
    PLUGIN_BACKEND_LOG="$MISSING_BACKEND_LOG" PATH="$PREFLIGHT_PATH" \
        "$INSTALLED_ROOT/skills/adversarial-review/scripts/run-review.sh"
) > "$PROFILE_ROOT/missing-claude.out" 2>&1
MISSING_CLAUDE_STATUS=$?
set -e
[[ $MISSING_CLAUDE_STATUS -eq 64 ]] || fail "missing Claude preflight returned an unexpected status"
grep -q "missing Agent backend executable: claude" "$PROFILE_ROOT/missing-claude.out" ||
    fail "missing Claude preflight was not actionable"
[[ ! -s "$MISSING_BACKEND_LOG" ]] ||
    fail "a review backend started before missing-backend preflight completed"

MISSING_TIMEOUT_BIN="$PROFILE_ROOT/missing-timeout-bin"
mkdir -p "$MISSING_TIMEOUT_BIN"
for utility in bash dirname git jq tr; do
    ln -s "$(command -v "$utility")" "$MISSING_TIMEOUT_BIN/$utility"
done
MISSING_TIMEOUT_LOG="$PROFILE_ROOT/missing-timeout-backends.log"
set +e
(
    cd "$TARGET_REPO"
    PLUGIN_BACKEND_LOG="$MISSING_TIMEOUT_LOG" PATH="$MISSING_TIMEOUT_BIN" \
        "$INSTALLED_ROOT/skills/adversarial-review/scripts/run-review.sh"
) > "$PROFILE_ROOT/missing-timeout.out" 2>&1
MISSING_TIMEOUT_STATUS=$?
set -e
[[ $MISSING_TIMEOUT_STATUS -eq 64 ]] || fail "missing timeout preflight returned an unexpected status"
grep -q "missing timeout support" "$PROFILE_ROOT/missing-timeout.out" ||
    fail "missing timeout preflight was not actionable"
[[ ! -s "$MISSING_TIMEOUT_LOG" ]] ||
    fail "a review backend started before missing-timeout preflight completed"

CODEX_ONLY_TARGET="$PROFILE_ROOT/codex-only-target"
mkdir -p "$CODEX_ONLY_TARGET"
git -C "$CODEX_ONLY_TARGET" init -q
git -C "$CODEX_ONLY_TARGET" config user.name "Plugin E2E"
git -C "$CODEX_ONLY_TARGET" config user.email "plugin-e2e@example.com"
printf '%s\n' 'committed' > "$CODEX_ONLY_TARGET/app.sh"
git -C "$CODEX_ONLY_TARGET" add app.sh
git -C "$CODEX_ONLY_TARGET" commit -qm initial
printf '%s\n' 'review me' >> "$CODEX_ONLY_TARGET/app.sh"
set +e
(
    cd "$CODEX_ONLY_TARGET"
    PATH="$PREFLIGHT_PATH" "$INSTALLED_ROOT/skills/adversarial-review/scripts/run-review.sh" \
        --slot-a codex --slot-b codex
) > "$PROFILE_ROOT/codex-only.out" 2>&1
CODEX_ONLY_STATUS=$?
set -e
[[ $CODEX_ONLY_STATUS -eq 10 ]] || {
    cat "$PROFILE_ROOT/codex-only.out" >&2
    fail "installed Skill could not run with one explicitly selected backend"
}
grep -q "same-model redundancy provides lower review diversity" "$PROFILE_ROOT/codex-only.out" ||
    fail "same-model redundancy diversity limitation was not reported"

echo "ok - installed Skill performs dependency preflight and supports explicit same-model redundancy"

PLUGIN_BACKEND_LOG="$PROFILE_ROOT/apply-backends.log"
export PLUGIN_BACKEND_LOG
export PLUGIN_APPLY_FIXES=true
set +e
(
    cd "$TARGET_REPO"
    PATH="$FAKE_BIN:$PATH" "$INSTALLED_ROOT/skills/adversarial-review/scripts/run-review.sh" \
        --apply-fixes --fixer claude \
        --verification-command bash --verification-arg -n --verification-arg app.sh
) > "$PROFILE_ROOT/apply.out" 2>&1
APPLY_STATUS=$?
set -e
unset PLUGIN_APPLY_FIXES PLUGIN_BACKEND_LOG

[[ $APPLY_STATUS -eq 0 ]] || {
    cat "$PROFILE_ROOT/apply.out" >&2
    fail "installed Skill apply-fixes invocation did not complete cleanly"
}
grep -q "Applied fixes (1): app.sh" "$PROFILE_ROOT/apply.out" ||
    fail "installed Skill did not report machine-result applied paths"
grep -q "Target Repo Diff (1): app.sh" "$PROFILE_ROOT/apply.out" ||
    fail "installed Skill did not report Target Repo diff paths"
grep -q "Remaining findings: in scope 0; pre-existing 0" "$PROFILE_ROOT/apply.out" ||
    fail "installed Skill did not report remaining Finding Scope counts"
grep -q "Verification result: passed" "$PROFILE_ROOT/apply.out" ||
    fail "installed Skill did not report verification success"
grep -q "fixed by Phase 4" "$TARGET_REPO/app.sh" ||
    fail "the authorized Phase 4 Fixer did not modify the Target Repo"

STATE_DIR="$(sed -n 's/^State: //p' "$PROFILE_ROOT/apply.out" | tail -1)"
[[ -n "$STATE_DIR" && -d "$STATE_DIR/artifacts" ]] ||
    fail "installed Skill did not report a usable audit artifact path"
INVOCATION_DIR="$STATE_DIR/artifacts"
mapfile -t WRITE_INVOCATIONS < <(
    find "$INVOCATION_DIR" -name '*.invocation.json' -type f -exec \
        jq -r 'select(.write_authorized == true) | [.phase, .agent] | @tsv' {} +
)
[[ ${#WRITE_INVOCATIONS[@]} -gt 0 ]] ||
    fail "the Phase 4 Fixer did not receive write authorization"
for invocation in "${WRITE_INVOCATIONS[@]}"; do
    [[ "$invocation" == $'phase_4\tclaude' ]] ||
        fail "write authorization was not restricted to the Phase 4 Fixer"
done
if find "$INVOCATION_DIR" -name '*.invocation.json' -type f -exec \
    jq -e 'select(.phase != "phase_4" and .write_authorized != false)' {} + | grep -q .; then
    fail "a review-phase invocation received write authorization"
fi

echo "ok - installed Skill apply-fixes limits writes to Phase 4 and reports results"
