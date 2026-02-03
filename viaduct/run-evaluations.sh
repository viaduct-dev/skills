#!/bin/bash
#
# Viaduct Skill Evaluation Harness (Shell version)
#
# Runs evaluations against the viaduct skill using viaduct-batteries-included.
# Each evaluation:
#   1. Clones viaduct-batteries-included
#   2. Checks out baseline commit (before features were added)
#   3. Runs Claude with the skill to implement the feature
#   4. Runs ./gradlew build to verify compilation
#   5. Checks for expected patterns in generated code
#
# Usage:
#   ./run-evaluations.sh [eval-id]
#
# Requirements:
#   - Claude Code CLI installed
#   - ANTHROPIC_API_KEY set
#   - Java 17+ and Gradle
#   - Git access to viaduct-dev/viaduct-batteries-included
#

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$SCRIPT_DIR"  # The skill directory (where this script lives)
EVAL_FILE="$SCRIPT_DIR/evaluations.json"
WORKSPACE_DIR="/tmp/viaduct-skill-eval"  # Use /tmp to avoid recursive copy
OUTPUT_DIR="$SCRIPT_DIR/.eval-outputs"

REPO_URL="git@github.com:viaduct-dev/viaduct-batteries-included.git"
BASELINE_COMMIT="a20f9be"  # Before validation features were added

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

mkdir -p "$WORKSPACE_DIR"
mkdir -p "$OUTPUT_DIR"

# Check dependencies
check_deps() {
    local missing=0

    if ! command -v jq &> /dev/null; then
        echo -e "${RED}Error: jq is required. Install with: brew install jq${NC}"
        missing=1
    fi

    if ! command -v claude &> /dev/null; then
        echo -e "${RED}Error: claude CLI is required.${NC}"
        missing=1
    fi

    if ! command -v git &> /dev/null; then
        echo -e "${RED}Error: git is required.${NC}"
        missing=1
    fi

    if ! command -v java &> /dev/null; then
        echo -e "${RED}Error: java is required (17+).${NC}"
        missing=1
    fi

    if [[ $missing -eq 1 ]]; then
        exit 1
    fi
}

run_evaluation() {
    local eval_id="$1"
    local eval_name="$2"
    local eval_query="$3"
    local verify_patterns="$4"

    local work_dir="$WORKSPACE_DIR/$eval_id"
    local claude_output="$OUTPUT_DIR/$eval_id-claude.txt"
    local build_output="$OUTPUT_DIR/$eval_id-build.txt"

    echo ""
    echo "============================================================"
    echo -e "${YELLOW}$eval_id: $eval_name${NC}"
    echo "============================================================"

    # Clean up previous run
    rm -rf "$work_dir"

    # Clone repository
    echo "  Cloning repository..."
    if ! git clone --quiet "$REPO_URL" "$work_dir" 2>/dev/null; then
        echo -e "  ${RED}Failed to clone repository${NC}"
        return 1
    fi

    # Checkout baseline
    echo "  Checking out baseline ($BASELINE_COMMIT)..."
    if ! (cd "$work_dir" && git checkout --quiet "$BASELINE_COMMIT" 2>/dev/null); then
        echo -e "  ${RED}Failed to checkout baseline${NC}"
        return 1
    fi

    # Copy skill into project (excluding workspace/output dirs)
    echo "  Installing skill..."
    mkdir -p "$work_dir/.claude/skills/viaduct"
    rsync -a --exclude='.eval-workspace' --exclude='.eval-outputs' --exclude='node_modules' --exclude='eval-kotlin/build' --exclude='eval-kotlin/.gradle' "$SKILL_DIR/" "$work_dir/.claude/skills/viaduct/"

    # Start Supabase (requires podman)
    echo "  Starting Supabase..."
    (cd "$work_dir" && podman machine start 2>/dev/null || true)
    if ! (cd "$work_dir" && supabase start > /dev/null 2>&1); then
        echo -e "  ${YELLOW}Warning: Supabase start failed (may already be running)${NC}"
    fi

    # Get IAP auth token for internal gateway
    echo "  Getting IAP auth token..."
    local auth_token
    auth_token=$(iap-auth https://devaigateway.a.musta.ch 2>/dev/null)
    if [[ -z "$auth_token" ]]; then
        echo -e "  ${RED}Failed to get IAP auth token${NC}"
        return 1
    fi

    # Run Claude in non-interactive mode with internal gateway
    echo "  Running Claude with skill..."
    echo "  Query: ${eval_query:0:60}..."

    if ! CLAUDE_CODE_USE_BEDROCK=1 \
         ANTHROPIC_BEDROCK_BASE_URL="https://devaigateway.a.musta.ch/bedrock" \
         CLAUDE_CODE_SKIP_BEDROCK_AUTH=1 \
         ANTHROPIC_AUTH_TOKEN="$auth_token" \
         claude -p "$eval_query" \
               --allowedTools "Read,Glob,Grep,Write,Edit,Bash" \
               --no-session-persistence \
               --permission-mode "acceptEdits" \
               "$work_dir" > "$claude_output" 2>&1; then
        echo -e "  ${RED}Claude execution failed${NC}"
    fi

    # Run gradle build (gradlew is in backend/)
    # Set Supabase env vars from mise.toml defaults
    echo "  Running gradle build..."
    local build_success=0
    export SUPABASE_URL="http://127.0.0.1:54321"
    export SUPABASE_ANON_KEY="sb_publishable_ACJWlzQHlZjBrEguHvfOxg_3BJgxAaH"
    export SUPABASE_SERVICE_ROLE_KEY="sb_secret_N7UND0UgjKTVK-Uodkm0Hg_xSvEMPvz"
    if (cd "$work_dir/backend" && ./gradlew classes --no-daemon -q > "$build_output" 2>&1); then
        build_success=1
        echo -e "  ${GREEN}Build: PASSED${NC}"
    else
        echo -e "  ${RED}Build: FAILED${NC}"
        echo "  Last 10 lines of build output:"
        tail -10 "$build_output" | sed 's/^/    /'
    fi

    # Check patterns
    local patterns_found=0
    local patterns_total=0

    if [[ -n "$verify_patterns" ]]; then
        echo "  Checking patterns..."
        while IFS= read -r pattern; do
            if [[ -n "$pattern" ]]; then
                ((patterns_total++))
                if grep -rqE "$pattern" "$work_dir/backend/src" 2>/dev/null; then
                    ((patterns_found++))
                    echo -e "    ${GREEN}✓${NC} $pattern"
                else
                    echo -e "    ${RED}✗${NC} $pattern"
                fi
            fi
        done <<< "$verify_patterns"
    fi

    # Determine result
    local passed=0
    if [[ $build_success -eq 1 ]] && [[ $patterns_found -eq $patterns_total ]]; then
        passed=1
    fi

    if [[ $passed -eq 1 ]]; then
        echo -e "\n  ${GREEN}✅ PASSED${NC}"
        return 0
    else
        echo -e "\n  ${RED}❌ FAILED${NC}"
        return 1
    fi
}

main() {
    local filter="${1:-}"

    echo "Viaduct Skill Evaluation Harness"
    echo "================================"
    echo "Repository: $REPO_URL"
    echo "Baseline: $BASELINE_COMMIT"
    echo "Skill: $SCRIPT_DIR"
    echo ""

    check_deps

    # Get evaluation count
    local eval_count
    eval_count=$(jq length "$EVAL_FILE")

    local passed=0
    local failed=0
    local skipped=0

    for i in $(seq 0 $((eval_count - 1))); do
        local eval_id eval_name eval_query verify_patterns
        eval_id=$(jq -r ".[$i].id" "$EVAL_FILE")
        eval_name=$(jq -r ".[$i].name" "$EVAL_FILE")
        eval_query=$(jq -r ".[$i].query" "$EVAL_FILE")
        verify_patterns=$(jq -r ".[$i].verify_patterns | .[]?" "$EVAL_FILE" 2>/dev/null || echo "")

        # Skip if filter provided and doesn't match
        if [[ -n "$filter" && "$eval_id" != "$filter" && "$eval_name" != *"$filter"* ]]; then
            ((skipped++))
            continue
        fi

        if run_evaluation "$eval_id" "$eval_name" "$eval_query" "$verify_patterns"; then
            ((passed++))
        else
            ((failed++))
        fi
    done

    # Summary
    echo ""
    echo "============================================================"
    echo "SUMMARY"
    echo "============================================================"
    echo -e "Passed: ${GREEN}$passed${NC}"
    echo -e "Failed: ${RED}$failed${NC}"
    if [[ $skipped -gt 0 ]]; then
        echo "Skipped: $skipped"
    fi
    echo ""
    echo "Outputs saved to: $OUTPUT_DIR"

    if [[ $failed -gt 0 ]]; then
        exit 1
    fi
}

main "$@"
