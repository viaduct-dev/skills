#!/bin/bash
#
# Viaduct Skill Evaluation Harness (Parallel Edition)
#
# Runs evaluations against the viaduct skill.
# Each evaluation:
#   1. Copies base-template to unique temp directory
#   2. Appends eval-specific schema types
#   3. Runs Gradle to generate scaffolding
#   4. Runs AI agent (Claude CLI or Crush) to implement the feature
#   5. Builds and verifies patterns
#
# Usage:
#   ./run-evaluations.sh [options] [eval-id]
#
# Options:
#   --no-skill      Run without the viaduct skill (baseline test)
#   --skill         Run with the viaduct skill (default)
#   --parallel=N    Run N evaluations in parallel (default: 10 for Crush, 4 for Claude)
#   --sequential    Run evaluations one at a time (--parallel=1)
#   --backend=X     Use 'crush' (default) or 'claude' as the AI backend
#
# Environment:
#   MAX_RETRIES=3       Set max retry attempts
#   MAX_PARALLEL=10     Set max parallel evaluations (default: 10 for Crush, 4 for Claude)
#
# Output:
#   .eval-outputs/<eval-id>-agent.txt     Agent's final response
#   .eval-outputs/<eval-id>-build.txt     Gradle build output
#   .eval-outputs/<eval-id>-errors.txt    Error summary
#   .eval-outputs/<eval-id>-workspace/    Full workspace (preserved on failure or retry)
#
# Backends:
#   crush   - Charmbracelet Crush (~165 MB/process, default, requires crush CLI)
#             Crush requires: CATWALK_URL=http://localhost:1 to use cached providers
#   claude  - Claude CLI (~800 MB/process, requires claude CLI)
#

set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
EVAL_FILE="$SCRIPT_DIR/evaluations.json"
OUTPUT_DIR="$SCRIPT_DIR/.eval-outputs"
BASE_TEMPLATE="$SCRIPT_DIR/base-template"
WORK_BASE="/tmp/viaduct-skill-eval"

# Default settings
USE_SKILL=1
FILTER=""
MAX_RETRIES="${MAX_RETRIES:-3}"
BACKEND="${BACKEND:-crush}"
# MAX_PARALLEL default depends on backend (set after parsing args)

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Parse arguments
EXPLICIT_PARALLEL=""
while [[ $# -gt 0 ]]; do
    case $1 in
        --no-skill)
            USE_SKILL=0
            shift
            ;;
        --skill)
            USE_SKILL=1
            shift
            ;;
        --parallel=*)
            EXPLICIT_PARALLEL="${1#*=}"
            shift
            ;;
        --sequential)
            EXPLICIT_PARALLEL=1
            shift
            ;;
        --backend=*)
            BACKEND="${1#*=}"
            shift
            ;;
        --crush)
            BACKEND="crush"
            shift
            ;;
        --claude)
            BACKEND="claude"
            shift
            ;;
        *)
            FILTER="$1"
            shift
            ;;
    esac
done

# Set MAX_PARALLEL based on backend (crush uses less memory, can run more parallel)
if [[ -n "$EXPLICIT_PARALLEL" ]]; then
    MAX_PARALLEL="$EXPLICIT_PARALLEL"
elif [[ -n "$MAX_PARALLEL" ]]; then
    : # Use environment variable
elif [[ "$BACKEND" == "crush" ]]; then
    MAX_PARALLEL=10
else
    MAX_PARALLEL=4
fi

mkdir -p "$OUTPUT_DIR"

check_deps() {
    local missing=0
    command -v jq &>/dev/null || { echo -e "${RED}Error: jq required${NC}"; missing=1; }
    command -v java &>/dev/null || { echo -e "${RED}Error: java 17+ required${NC}"; missing=1; }
    [[ ! -d "$BASE_TEMPLATE" ]] && { echo -e "${RED}Error: base-template not found at $BASE_TEMPLATE${NC}"; missing=1; }

    if [[ "$BACKEND" == "crush" ]]; then
        command -v crush &>/dev/null || { echo -e "${RED}Error: crush CLI required (brew install charmbracelet/tap/crush)${NC}"; missing=1; }
    else
        command -v claude &>/dev/null || { echo -e "${RED}Error: claude CLI required${NC}"; missing=1; }
    fi

    [[ $missing -eq 1 ]] && exit 1
}

# Timer helper
time_cmd() {
    local start=$(date +%s)
    "$@"
    local end=$(date +%s)
    echo $((end - start))
}

# Pre-warm Gradle daemon and download dependencies
prewarm_gradle() {
    echo "Pre-warming Gradle daemon and cache..."
    local prewarm_dir="$WORK_BASE-prewarm"
    local start=$(date +%s)

    rm -rf "$prewarm_dir"
    cp -r "$BASE_TEMPLATE" "$prewarm_dir"

    # Run a build to warm up the daemon and cache dependencies
    if (cd "$prewarm_dir" && ./gradlew viaductCodegen classes --daemon -q 2>&1); then
        local end=$(date +%s)
        echo -e "${GREEN}Gradle daemon warmed up${NC} ($(( end - start ))s)"
    else
        echo -e "${YELLOW}Warning: Gradle prewarm had issues, continuing anyway${NC}"
    fi
    rm -rf "$prewarm_dir"
}

setup_project() {
    local work_dir="$1"
    local schema_addition="$2"
    local eval_id="$3"

    # Clean and copy base template
    rm -rf "$work_dir"
    cp -r "$BASE_TEMPLATE" "$work_dir"

    # Append schema types for this evaluation
    if [[ -n "$schema_addition" ]]; then
        echo "" >> "$work_dir/src/main/viaduct/schema/Schema.graphqls"
        echo "$schema_addition" >> "$work_dir/src/main/viaduct/schema/Schema.graphqls"
    fi

    # Generate scaffolding with Gradle (using daemon for speed)
    if ! (cd "$work_dir" && ./gradlew viaductCodegen --daemon -q 2>&1); then
        return 1
    fi

    # Install AGENTS.md with doc references if in skill mode
    if [[ $USE_SKILL -eq 1 ]]; then
        (cd "$work_dir" && node "$SCRIPT_DIR/../bin/install.js") > /dev/null 2>&1
    fi

    return 0
}

# Setup Crush environment (configure providers for internal gateway)
setup_crush_providers() {
    # Crush auto-updates providers from remote, which overwrites local changes.
    # We need to modify the cached providers.json to use gateway model IDs.
    local providers_file="$HOME/.local/share/crush/providers.json"

    if [[ ! -f "$providers_file" ]]; then
        echo -e "${YELLOW}Warning: Crush providers.json not found, running crush once to initialize...${NC}"
        CATWALK_URL="http://localhost:1" crush models > /dev/null 2>&1 || true
    fi

    if [[ -f "$providers_file" ]]; then
        # Update Anthropic provider model IDs to match gateway format
        python3 << 'PYEOF' 2>/dev/null || true
import json, os

filepath = os.path.expanduser('~/.local/share/crush/providers.json')
if not os.path.exists(filepath):
    exit(0)

with open(filepath, 'r') as f:
    data = json.load(f)

modified = False
for provider in data:
    if provider.get('id') == 'anthropic':
        for model in provider.get('models', []):
            old_id = model['id']
            if not old_id.startswith('global.'):
                model['id'] = f"global.anthropic.{old_id}-v1:0"
                modified = True
        if not provider.get('default_large_model_id', '').startswith('global.'):
            provider['default_large_model_id'] = 'global.anthropic.claude-sonnet-4-5-20250929-v1:0'
            provider['default_small_model_id'] = 'global.anthropic.claude-haiku-4-5-20251001-v1:0'
            modified = True
        break

if modified:
    with open(filepath, 'w') as f:
        json.dump(data, f, separators=(',', ':'))
PYEOF
    fi
}

# Run prompt with Claude CLI
run_with_claude() {
    local work_dir="$1"
    local prompt="$2"
    local output_file="$3"

    if [[ -n "$ANTHROPIC_API_KEY" ]]; then
        claude -p "$prompt" \
              --dangerously-skip-permissions \
              --no-session-persistence \
              "$work_dir" >> "$output_file" 2>&1 || true
    elif command -v iap-auth &>/dev/null; then
        local auth_token
        auth_token=$(iap-auth https://devaigateway.a.musta.ch 2>/dev/null)
        if [[ -z "$auth_token" ]]; then
            return 1
        fi
        CLAUDE_CODE_USE_BEDROCK=1 \
        ANTHROPIC_BEDROCK_BASE_URL="https://devaigateway.a.musta.ch/bedrock" \
        CLAUDE_CODE_SKIP_BEDROCK_AUTH=1 \
        ANTHROPIC_AUTH_TOKEN="$auth_token" \
        claude -p "$prompt" \
              --dangerously-skip-permissions \
              --no-session-persistence \
              "$work_dir" >> "$output_file" 2>&1 || true
    else
        return 1
    fi
    return 0
}

# Run prompt with Crush
run_with_crush() {
    local work_dir="$1"
    local prompt="$2"
    local output_file="$3"

    local auth_token=""
    if [[ -n "$ANTHROPIC_API_KEY" ]]; then
        auth_token="$ANTHROPIC_API_KEY"
    elif command -v iap-auth &>/dev/null; then
        auth_token=$(iap-auth https://devaigateway.a.musta.ch 2>/dev/null)
    fi

    if [[ -z "$auth_token" ]]; then
        return 1
    fi

    # Run Crush with gateway configuration
    # CATWALK_URL blocks remote provider fetch, using our modified local providers
    (
        cd "$work_dir"
        ANTHROPIC_API_KEY="$auth_token" \
        ANTHROPIC_API_ENDPOINT="https://devaigateway.a.musta.ch" \
        CATWALK_URL="http://localhost:1" \
        crush run "$prompt" >> "$output_file" 2>&1
    ) || true
    return 0
}

# Run prompt with selected backend
run_agent() {
    local work_dir="$1"
    local prompt="$2"
    local output_file="$3"

    if [[ "$BACKEND" == "crush" ]]; then
        run_with_crush "$work_dir" "$prompt" "$output_file"
    else
        run_with_claude "$work_dir" "$prompt" "$output_file"
    fi
}

# Extract the key error from build output
extract_error_summary() {
    local build_output="$1"

    if grep -q "Unresolved reference" "$build_output" 2>/dev/null; then
        grep "Unresolved reference" "$build_output" | head -1 | sed 's/.*: //'
    elif grep -q "cannot find symbol" "$build_output" 2>/dev/null; then
        grep "cannot find symbol" "$build_output" | head -1
    elif grep -q "not found" "$build_output" 2>/dev/null; then
        grep -E "not found|Not found" "$build_output" | head -1 | sed 's/.*: //'
    elif grep -q "expected" "$build_output" 2>/dev/null; then
        grep "expected" "$build_output" | head -1
    elif grep -q "error:" "$build_output" 2>/dev/null; then
        grep "error:" "$build_output" | head -1 | sed 's/.*error: //'
    else
        tail -3 "$build_output" | head -1
    fi
}

# Run a single evaluation (can be called in parallel)
# Writes result to $OUTPUT_DIR/<eval_id>.result
run_evaluation() {
    local eval_id="$1"
    local eval_name="$2"
    local eval_query="$3"
    local verify_patterns="$4"
    local schema_addition="$5"
    local negative_patterns="$6"

    local suffix=$([[ $USE_SKILL -eq 0 ]] && echo "-noskill" || echo "")
    local backend_suffix=$([[ "$BACKEND" == "crush" ]] && echo "-crush" || echo "")

    # Unique workspace for this evaluation (includes suffix to avoid conflicts)
    local work_dir="$WORK_BASE-$eval_id$suffix$backend_suffix"
    local agent_output="$OUTPUT_DIR/$eval_id$suffix$backend_suffix-agent.txt"
    local build_output="$OUTPUT_DIR/$eval_id$suffix$backend_suffix-build.txt"
    local errors_file="$OUTPUT_DIR/$eval_id$suffix$backend_suffix-errors.txt"
    local result_file="$OUTPUT_DIR/$eval_id$suffix$backend_suffix.result"

    # Log start
    local eval_start=$(date +%s)
    echo "[$(date +%H:%M:%S)] Starting: $eval_id"

    # Setup fresh project with schema for this eval
    local setup_start=$(date +%s)
    if ! setup_project "$work_dir" "$schema_addition" "$eval_id"; then
        echo "FAIL|$eval_id|0|SETUP_FAILED" > "$result_file"
        echo "[$(date +%H:%M:%S)] $eval_id: SETUP FAILED"
        return 1
    fi

    local setup_end=$(date +%s)
    local setup_time=$((setup_end - setup_start))

    # Clear errors file
    > "$errors_file"

    # Build query - remove skill reference if no-skill mode
    local full_query
    if [[ $USE_SKILL -eq 1 ]]; then
        full_query="Work ONLY in $work_dir. Implement:

$eval_query"
    else
        local clean_query="${eval_query//Use the viaduct skill for guidance./}"
        clean_query="${clean_query//Use the viaduct skill for guidance/}"
        full_query="Work ONLY in $work_dir. Implement:

$clean_query"
    fi

    # Run AI agent
    local agent_start=$(date +%s)
    > "$agent_output"  # Clear output file
    if ! run_agent "$work_dir" "$full_query" "$agent_output"; then
        echo "FAIL|$eval_id|0|AUTH_FAILED" > "$result_file"
        echo "[$(date +%H:%M:%S)] $eval_id: AUTH FAILED"
        return 1
    fi

    local agent_end=$(date +%s)
    local agent_time=$((agent_end - agent_start))

    # Build and fix loop
    local build_start=$(date +%s)
    local build_success=0
    local attempt=1
    local retry_errors=""

    while [[ $attempt -le $MAX_RETRIES ]]; do
        # Run viaductCodegen first in case Claude modified the schema
        if (cd "$work_dir" && ./gradlew viaductCodegen classes --daemon -q > "$build_output" 2>&1); then
            build_success=1
            break
        else
            local error_summary=$(extract_error_summary "$build_output")
            echo "Attempt $attempt: $error_summary" >> "$errors_file"
            [[ -n "$retry_errors" ]] && retry_errors="$retry_errors|"
            retry_errors="$retry_errors$error_summary"

            if [[ $attempt -lt $MAX_RETRIES ]]; then
                local build_error=$(tail -50 "$build_output")
                local fix_query="Build failed. Fix it:
\`\`\`
$build_error
\`\`\`
Work ONLY in $work_dir."

                run_agent "$work_dir" "$fix_query" "$agent_output"
            fi
        fi
        ((attempt++))
    done

    # Check patterns
    local patterns_found=0
    local patterns_total=0
    local missing_patterns=""

    if [[ -n "$verify_patterns" ]]; then
        while IFS= read -r pattern; do
            if [[ -n "$pattern" ]]; then
                ((patterns_total++))
                if grep -rqE "$pattern" "$work_dir/src" 2>/dev/null; then
                    ((patterns_found++))
                else
                    [[ -n "$missing_patterns" ]] && missing_patterns="$missing_patterns, "
                    missing_patterns="$missing_patterns$pattern"
                fi
            fi
        done <<< "$verify_patterns"
    fi

    # Check negative patterns
    local negative_failed=0
    local found_negative=""

    if [[ -n "$negative_patterns" ]]; then
        while IFS= read -r pattern; do
            if [[ -n "$pattern" ]]; then
                if grep -rqE "$pattern" "$work_dir/src" 2>/dev/null; then
                    [[ -n "$found_negative" ]] && found_negative="$found_negative, "
                    found_negative="$found_negative$pattern"
                    ((negative_failed++))
                fi
            fi
        done <<< "$negative_patterns"
    fi

    # Record results
    if [[ -n "$missing_patterns" ]]; then
        echo "Missing patterns: $missing_patterns" >> "$errors_file"
    fi
    if [[ -n "$found_negative" ]]; then
        echo "Forbidden patterns found: $found_negative" >> "$errors_file"
    fi

    local build_end=$(date +%s)
    local build_time=$((build_end - build_start))
    local total_time=$((build_end - eval_start))

    # Determine pass/fail
    local eval_passed=0
    local timing_info="setup:${setup_time}s agent:${agent_time}s build:${build_time}s total:${total_time}s"

    if [[ $build_success -eq 1 ]] && [[ $patterns_found -eq $patterns_total ]] && [[ $negative_failed -eq 0 ]]; then
        echo "PASS|$eval_id|$attempt|$retry_errors|$timing_info" > "$result_file"
        echo -e "[$(date +%H:%M:%S)] $eval_id: ${GREEN}PASSED${NC} (attempt $attempt) [$timing_info]"
        eval_passed=1
    else
        local fail_reason=""
        [[ $build_success -eq 0 ]] && fail_reason="build_failed"
        [[ $patterns_found -ne $patterns_total ]] && fail_reason="${fail_reason:+$fail_reason,}missing_patterns"
        [[ $negative_failed -gt 0 ]] && fail_reason="${fail_reason:+$fail_reason,}forbidden_patterns"
        echo "FAIL|$eval_id|$attempt|$fail_reason|$retry_errors|$timing_info" > "$result_file"
        echo -e "[$(date +%H:%M:%S)] $eval_id: ${RED}FAILED${NC} ($fail_reason) [$timing_info]"
    fi

    # Preserve workspace if failed OR not a one-shot
    if [[ $eval_passed -eq 0 ]] || [[ $attempt -gt 1 ]]; then
        local workspace_dir="$OUTPUT_DIR/$eval_id$suffix-workspace"
        rm -rf "$workspace_dir"
        cp -r "$work_dir" "$workspace_dir"
    fi

    # Clean up temp workspace
    rm -rf "$work_dir"

    [[ $eval_passed -eq 1 ]] && return 0 || return 1
}

# Export functions and variables for parallel execution
export -f run_evaluation setup_project extract_error_summary run_agent run_with_claude run_with_crush
export SCRIPT_DIR OUTPUT_DIR BASE_TEMPLATE WORK_BASE USE_SKILL MAX_RETRIES BACKEND
export RED GREEN YELLOW BLUE CYAN NC

main() {
    echo "Viaduct Skill Evaluation Harness (Parallel Edition)"
    echo "===================================================="
    echo "Base template: $BASE_TEMPLATE"
    echo "Work directory: $WORK_BASE-<eval-id>"
    [[ $USE_SKILL -eq 1 ]] && echo -e "Mode: ${GREEN}WITH SKILL${NC}" || echo -e "Mode: ${BLUE}NO SKILL${NC}"
    if [[ "$BACKEND" == "crush" ]]; then
        echo -e "Backend: ${CYAN}Crush${NC} (~165 MB/process)"
    else
        echo -e "Backend: ${CYAN}Claude CLI${NC} (~800 MB/process)"
    fi
    echo "Max retries: $MAX_RETRIES"
    echo -e "Parallelism: ${CYAN}$MAX_PARALLEL${NC} concurrent evaluations"
    echo ""

    check_deps

    # Setup Crush providers if using Crush backend
    if [[ "$BACKEND" == "crush" ]]; then
        echo "Configuring Crush providers for gateway..."
        setup_crush_providers
    fi

    # Pre-warm Gradle daemon
    prewarm_gradle

    # Get list of evaluations to run
    local eval_count=$(jq length "$EVAL_FILE")
    local evals_to_run=()

    for i in $(seq 0 $((eval_count - 1))); do
        local eval_id=$(jq -r ".[$i].id" "$EVAL_FILE")
        local eval_name=$(jq -r ".[$i].name" "$EVAL_FILE")

        # Filter check
        if [[ -n "$FILTER" && "$eval_id" != *"$FILTER"* && "$eval_name" != *"$FILTER"* ]]; then
            continue
        fi

        evals_to_run+=("$i")
    done

    local total_evals=${#evals_to_run[@]}
    echo "Running $total_evals evaluations..."
    echo ""

    # Clear old result files
    local suffix=$([[ $USE_SKILL -eq 0 ]] && echo "-noskill" || echo "")
    local backend_suffix=$([[ "$BACKEND" == "crush" ]] && echo "-crush" || echo "")
    rm -f "$OUTPUT_DIR"/*$suffix$backend_suffix.result 2>/dev/null

    # Track running jobs
    local running_pids=()
    local running_evals=()
    local completed=0

    for idx in "${evals_to_run[@]}"; do
        local eval_id=$(jq -r ".[$idx].id" "$EVAL_FILE")
        local eval_name=$(jq -r ".[$idx].name" "$EVAL_FILE")
        local eval_query=$(jq -r ".[$idx].query" "$EVAL_FILE")
        local verify_patterns=$(jq -r ".[$idx].verify_patterns | .[]?" "$EVAL_FILE" 2>/dev/null || echo "")
        local schema_addition=$(jq -r ".[$idx].schema // empty" "$EVAL_FILE" 2>/dev/null || echo "")
        local negative_patterns=$(jq -r ".[$idx].negative_patterns | .[]?" "$EVAL_FILE" 2>/dev/null || echo "")

        # Wait if we've hit max parallelism
        while [[ ${#running_pids[@]} -ge $MAX_PARALLEL ]]; do
            # Wait for any job to finish
            local new_pids=()
            local new_evals=()
            for i in "${!running_pids[@]}"; do
                if kill -0 "${running_pids[$i]}" 2>/dev/null; then
                    new_pids+=("${running_pids[$i]}")
                    new_evals+=("${running_evals[$i]}")
                else
                    ((completed++))
                    echo -e "${CYAN}[$completed/$total_evals completed]${NC}"
                fi
            done
            running_pids=("${new_pids[@]}")
            running_evals=("${new_evals[@]}")

            if [[ ${#running_pids[@]} -ge $MAX_PARALLEL ]]; then
                sleep 1
            fi
        done

        # Start evaluation in background
        run_evaluation "$eval_id" "$eval_name" "$eval_query" "$verify_patterns" "$schema_addition" "$negative_patterns" &
        running_pids+=($!)
        running_evals+=("$eval_id")
    done

    # Wait for all remaining jobs
    echo "Waiting for remaining evaluations to complete..."
    for pid in "${running_pids[@]}"; do
        wait "$pid" 2>/dev/null || true
    done

    # Collect results
    echo ""
    echo "============================================================"
    echo "SUMMARY"
    echo "============================================================"

    local passed=0 failed=0 one_shot=0

    [[ $USE_SKILL -eq 1 ]] && echo -e "Mode: ${GREEN}WITH SKILL${NC}" || echo -e "Mode: ${BLUE}NO SKILL${NC}"

    echo ""
    echo "DETAILED RESULTS:"
    echo "-----------------"

    for idx in "${evals_to_run[@]}"; do
        local eval_id=$(jq -r ".[$idx].id" "$EVAL_FILE")
        local result_file="$OUTPUT_DIR/$eval_id$suffix$backend_suffix.result"

        if [[ -f "$result_file" ]]; then
            local result=$(cat "$result_file")
            local status=$(echo "$result" | cut -d'|' -f1)
            local attempt=$(echo "$result" | cut -d'|' -f3)
            local errors=$(echo "$result" | cut -d'|' -f4-)

            if [[ "$status" == "PASS" ]]; then
                ((passed++))
                if [[ "$attempt" == "1" ]]; then
                    ((one_shot++))
                    echo -e "${GREEN}✓${NC} $eval_id - ${GREEN}one-shot${NC}"
                else
                    echo -e "${GREEN}✓${NC} $eval_id - attempt $attempt"
                    if [[ -n "$errors" ]]; then
                        echo -e "    ${CYAN}retries: $errors${NC}"
                    fi
                fi
            else
                ((failed++))
                local fail_reason=$(echo "$result" | cut -d'|' -f4)
                echo -e "${RED}✗${NC} $eval_id - FAILED ($fail_reason)"
                local errors_file="$OUTPUT_DIR/$eval_id$suffix$backend_suffix-errors.txt"
                if [[ -f "$errors_file" ]] && [[ -s "$errors_file" ]]; then
                    while IFS= read -r line; do
                        echo -e "    ${CYAN}$line${NC}"
                    done < "$errors_file"
                fi
            fi
        else
            ((failed++))
            echo -e "${RED}✗${NC} $eval_id - NO RESULT FILE"
        fi
    done

    echo ""
    echo "============================================================"
    echo -e "Passed: ${GREEN}$passed${NC} / $((passed + failed))"
    echo -e "One-shot: ${GREEN}$one_shot${NC} / $passed"
    echo -e "Failed: ${RED}$failed${NC}"
    echo ""
    echo "Outputs: $OUTPUT_DIR"

    # List preserved workspaces
    local workspaces=$(ls -d "$OUTPUT_DIR"/*-workspace 2>/dev/null | wc -l | tr -d ' ')
    if [[ "$workspaces" -gt 0 ]]; then
        echo -e "${CYAN}Preserved workspaces (failed or retried):${NC}"
        for ws in "$OUTPUT_DIR"/*-workspace; do
            [[ -d "$ws" ]] && echo "  $(basename "$ws")"
        done
    fi

    [[ $failed -gt 0 ]] && exit 1
    exit 0
}

main
