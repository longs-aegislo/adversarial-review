#!/usr/bin/env bash
#
# The repository ships two copies of the Adversarial Review Skill:
#   .agents/skills/adversarial-review/            (source-repository Skill)
#   plugins/adversarial-review/skills/adversarial-review/ (bundled into the Plugin)
#
# Some content must intentionally differ between them (the Plugin pins its
# CLI to a bundled runtime and rejects overrides; the source Skill looks on
# PATH/repo root and allows ADVERSARIAL_REVIEW_BIN/--cli). This suite does
# not diff the whole files. It only asserts that the fields both copies are
# expected to share in lockstep have not silently drifted apart.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_SKILL="$REPO_ROOT/.agents/skills/adversarial-review"
PLUGIN_SKILL="$REPO_ROOT/plugins/adversarial-review/skills/adversarial-review"

tests_run=0

fail() {
    echo "not ok - $1" >&2
    exit 1
}

pass() {
    tests_run=$((tests_run + 1))
    echo "ok $tests_run - $1"
}

frontmatter_of() {
    awk '/^---$/{c++; next} c==1' "$1"
}

yaml_scalar() {
    # Extracts a top-level or one-level-nested "key: value" scalar, stripping
    # surrounding double quotes. Fails closed (empty output) on lists/maps.
    local file="$1" key="$2"
    grep -m1 -E "^[[:space:]]*${key}:[[:space:]]" "$file" |
        sed -E "s/^[[:space:]]*${key}:[[:space:]]*//; s/^\"(.*)\"\$/\\1/"
}

test_skill_md_frontmatter_matches() {
    local source_frontmatter plugin_frontmatter

    [[ -f "$SOURCE_SKILL/SKILL.md" ]] || fail "source Skill SKILL.md is missing"
    [[ -f "$PLUGIN_SKILL/SKILL.md" ]] || fail "Plugin-bundled SKILL.md is missing"

    source_frontmatter="$(frontmatter_of "$SOURCE_SKILL/SKILL.md")"
    plugin_frontmatter="$(frontmatter_of "$PLUGIN_SKILL/SKILL.md")"

    [[ "$source_frontmatter" == "$plugin_frontmatter" ]] ||
        fail "SKILL.md frontmatter (name/description) differs between the source Skill and the Plugin-bundled copy"

    pass "SKILL.md frontmatter (name, description) matches between the source Skill and the Plugin-bundled copy"
}

test_openai_yaml_shared_fields_match() {
    local source_yaml="$SOURCE_SKILL/agents/openai.yaml"
    local plugin_yaml="$PLUGIN_SKILL/agents/openai.yaml"
    local key

    [[ -f "$source_yaml" ]] || fail "source Skill agents/openai.yaml is missing"
    [[ -f "$plugin_yaml" ]] || fail "Plugin-bundled agents/openai.yaml is missing"

    for key in display_name short_description allow_implicit_invocation; do
        local source_value plugin_value
        source_value="$(yaml_scalar "$source_yaml" "$key")"
        plugin_value="$(yaml_scalar "$plugin_yaml" "$key")"

        [[ -n "$source_value" ]] || fail "source Skill agents/openai.yaml is missing '$key'"
        [[ "$source_value" == "$plugin_value" ]] ||
            fail "agents/openai.yaml '$key' differs between the source Skill ('$source_value') and the Plugin-bundled copy ('$plugin_value')"
    done

    pass "agents/openai.yaml shared fields (display_name, short_description, allow_implicit_invocation) match between the source Skill and the Plugin-bundled copy"
}

test_openai_yaml_default_prompt_intentionally_diverges() {
    # Documents the known, allowed divergence so a future accidental fix that
    # re-synchronizes this field is caught here rather than silently
    # reverting the Plugin's apply-fixes-safety wording from #42.
    local source_prompt plugin_prompt

    source_prompt="$(yaml_scalar "$SOURCE_SKILL/agents/openai.yaml" default_prompt)"
    plugin_prompt="$(yaml_scalar "$PLUGIN_SKILL/agents/openai.yaml" default_prompt)"

    [[ -n "$source_prompt" && -n "$plugin_prompt" ]] ||
        fail "default_prompt must be set in both agents/openai.yaml copies"
    [[ "$source_prompt" != "$plugin_prompt" ]] ||
        fail "default_prompt unexpectedly matches between the source Skill and the Plugin-bundled copy; if this is now intentional, update this test's expectation"

    pass "agents/openai.yaml default_prompt keeps its known, intentional Plugin-specific wording"
}

test_skill_md_frontmatter_matches
test_openai_yaml_shared_fields_match
test_openai_yaml_default_prompt_intentionally_diverges

echo "1..$tests_run"
