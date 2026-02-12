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
#   --compare       Run with and without skill, then show side-by-side comparison
#   --clean         Remove all previous eval outputs before starting
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

# Clean up all child processes on exit
cleanup() {
    local pids=$(jobs -p 2>/dev/null)
    if [[ -n "$pids" ]]; then
        echo -e "\nCleaning up child processes..."
        kill $pids 2>/dev/null
        sleep 2
        kill -9 $pids 2>/dev/null
    fi
}
trap cleanup EXIT INT TERM

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
EVAL_FILE="$SCRIPT_DIR/evaluations.json"
OUTPUT_DIR="$SCRIPT_DIR/.eval-outputs"
BASE_TEMPLATE="$SCRIPT_DIR/base-template"
WORK_BASE="/tmp/viaduct-skill-eval"

# Default settings
USE_SKILL=1
CLEAN=0
COMPARE=0
FILTER=""
MAX_RETRIES="${MAX_RETRIES:-3}"
EVAL_TIMEOUT="${EVAL_TIMEOUT:-600}"  # 10 minutes per evaluation
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
        --clean)
            CLEAN=1
            shift
            ;;
        --compare)
            COMPARE=1
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

# Kill a process and all its children
kill_tree() {
    local pid="$1"
    local signal="${2:-TERM}"
    # Kill children first (process group), then the process itself
    local children=$(pgrep -P "$pid" 2>/dev/null)
    for child in $children; do
        kill_tree "$child" "$signal"
    done
    kill -"$signal" "$pid" 2>/dev/null || true
}

# Run a function with a timeout. Kills the process tree if it exceeds the limit.
# Usage: run_with_timeout <timeout_secs> <function> [args...]
run_with_timeout() {
    local timeout="$1"
    shift

    # Run the function in a subshell so we get a single PID to track
    "$@" &
    local cmd_pid=$!

    # Watchdog: sleep then kill if still running
    (
        sleep "$timeout"
        if kill -0 "$cmd_pid" 2>/dev/null; then
            echo -e "${RED}[$(date +%H:%M:%S)] TIMEOUT: killing evaluation (exceeded ${timeout}s)${NC}" >&2
            kill_tree "$cmd_pid" TERM
            sleep 5
            # Force kill if still alive
            if kill -0 "$cmd_pid" 2>/dev/null; then
                kill_tree "$cmd_pid" KILL
            fi
        fi
    ) &
    local watchdog_pid=$!

    # Wait for the command to finish (either naturally or killed)
    wait "$cmd_pid" 2>/dev/null
    local exit_code=$?

    # Clean up the watchdog
    kill "$watchdog_pid" 2>/dev/null
    wait "$watchdog_pid" 2>/dev/null

    return $exit_code
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
        local install_output
        install_output=$(cd "$work_dir" && node "$SCRIPT_DIR/../bin/install.js" 2>&1)
        local install_exit=$?

        if [[ $install_exit -ne 0 ]]; then
            echo -e "${RED}Warning: skill install failed for $eval_id (exit $install_exit)${NC}" >&2
            echo "$install_output" >&2
        fi

        # Verify docs were actually installed
        if [[ ! -f "$work_dir/AGENTS.md" && ! -f "$work_dir/CLAUDE.md" ]]; then
            echo -e "${RED}Warning: no AGENTS.md or CLAUDE.md found in $work_dir after install${NC}" >&2
        fi
        if [[ ! -d "$work_dir/.viaduct/agents" ]]; then
            echo -e "${RED}Warning: .viaduct/agents/ directory not created in $work_dir${NC}" >&2
        fi
    fi

    return 0
}

# Detect if we're using internal gateway or direct Anthropic API
# Sets USE_GATEWAY=1 if using internal gateway, 0 if using direct API
detect_auth_mode() {
    if [[ -n "$ANTHROPIC_API_KEY" ]]; then
        # Direct Anthropic API key provided
        USE_GATEWAY=0
    elif command -v iap-auth &>/dev/null; then
        # Internal gateway via iap-auth
        USE_GATEWAY=1
    else
        echo -e "${RED}Error: No authentication configured.${NC}"
        echo "Set ANTHROPIC_API_KEY for direct Anthropic API access,"
        echo "or ensure iap-auth is available for internal gateway access."
        exit 1
    fi
    export USE_GATEWAY
}

# Crush config directory (checked into repo)
CRUSH_CONFIG_DIR="$SCRIPT_DIR/crush"

# Run prompt with Claude CLI
# Uses --output-format json to capture token usage alongside agent output
run_with_claude() {
    local work_dir="$1"
    local prompt="$2"
    local output_file="$3"

    local json_tmp="$work_dir/.claude-response.json"
    local usage_log="$work_dir/.claude-usage.jsonl"

    local claude_args=(-p "$prompt" --output-format json --dangerously-skip-permissions --no-session-persistence "$work_dir")

    if [[ -n "$ANTHROPIC_API_KEY" ]]; then
        claude "${claude_args[@]}" > "$json_tmp" 2>&1 || true
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
        claude "${claude_args[@]}" > "$json_tmp" 2>&1 || true
    else
        return 1
    fi

    # Extract agent text into output file, append usage to log
    if [[ -f "$json_tmp" ]] && jq -e '.result' "$json_tmp" &>/dev/null; then
        jq -r '.result // empty' "$json_tmp" >> "$output_file"
        jq -c '{input_tokens: (.usage.input_tokens // 0), output_tokens: (.usage.output_tokens // 0), cache_creation: (.usage.cache_creation_input_tokens // 0), cache_read: (.usage.cache_read_input_tokens // 0), cost: (.total_cost_usd // 0)}' "$json_tmp" >> "$usage_log"
    else
        # Fallback: non-JSON output (e.g., error messages)
        cat "$json_tmp" >> "$output_file" 2>/dev/null || true
    fi
    rm -f "$json_tmp"

    return 0
}

# Run prompt with Crush
run_with_crush() {
    local work_dir="$1"
    local prompt="$2"
    local output_file="$3"

    (
        cd "$work_dir"
        if [[ "$USE_GATEWAY" -eq 1 ]]; then
            local auth_token
            auth_token=$(iap-auth https://devaigateway.a.musta.ch 2>/dev/null)
            if [[ -z "$auth_token" ]]; then
                echo "Failed to get iap-auth token" >> "$output_file"
                return 1
            fi
            # Use repo-local config with gateway model IDs
            XDG_CONFIG_HOME="$CRUSH_CONFIG_DIR/config" \
            XDG_DATA_HOME="$CRUSH_CONFIG_DIR/data" \
            ANTHROPIC_API_KEY="$auth_token" \
            ANTHROPIC_API_ENDPOINT="https://devaigateway.a.musta.ch" \
            CATWALK_URL="http://localhost:1" \
            crush run "$prompt" >> "$output_file" 2>&1
        else
            # Use repo-local config with standard model IDs
            XDG_CONFIG_HOME="$CRUSH_CONFIG_DIR/config-direct" \
            CATWALK_URL="http://localhost:1" \
            crush run "$prompt" >> "$output_file" 2>&1
        fi
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

# Extract token counts from backend session data
# Writes prompt_tokens|completion_tokens|cost to the tokens file
# Crush: reads SQLite sessions table
# Claude: reads .claude-usage.jsonl (one JSON line per invocation)
extract_tokens() {
    local work_dir="$1"
    local tokens_file="$2"

    local usage_log="$work_dir/.claude-usage.jsonl"
    local crush_db="$work_dir/.crush/crush.db"

    if [[ -f "$usage_log" ]]; then
        # Claude CLI: sum across all invocations (initial + retries)
        # input_tokens only counts non-cached tokens; include cache_creation + cache_read for total prompt
        local result
        result=$(jq -s '{pt: ([.[] | .input_tokens + .cache_creation + .cache_read] | add), ct: ([.[].output_tokens] | add), cost: ([.[].cost] | add)} | "\(.pt)|\(.ct)|\(.cost)"' "$usage_log" 2>/dev/null)
        # Strip quotes from jq string output
        result="${result//\"/}"
        echo "${result:-0|0|0}" > "$tokens_file"
    elif [[ -f "$crush_db" ]] && command -v sqlite3 &>/dev/null; then
        # Crush: read from SQLite
        local result
        result=$(sqlite3 "$crush_db" "SELECT COALESCE(SUM(prompt_tokens),0)||'|'||COALESCE(SUM(completion_tokens),0)||'|'||COALESCE(SUM(cost),0) FROM sessions" 2>/dev/null)
        echo "${result:-0|0|0}" > "$tokens_file"
    else
        echo "0|0|0" > "$tokens_file"
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

    # Extract token counts before cleanup
    local tokens_file="$OUTPUT_DIR/$eval_id$suffix$backend_suffix.tokens"
    extract_tokens "$work_dir" "$tokens_file"

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
export -f run_evaluation setup_project extract_error_summary extract_tokens run_agent run_with_claude run_with_crush kill_tree run_with_timeout
export SCRIPT_DIR OUTPUT_DIR BASE_TEMPLATE WORK_BASE USE_SKILL MAX_RETRIES EVAL_TIMEOUT BACKEND USE_GATEWAY CRUSH_CONFIG_DIR
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
    echo "Eval timeout: ${EVAL_TIMEOUT}s"
    echo -e "Parallelism: ${CYAN}$MAX_PARALLEL${NC} concurrent evaluations"
    echo ""

    check_deps

    # Clean old outputs if requested
    if [[ $CLEAN -eq 1 ]]; then
        echo -e "${YELLOW}Cleaning eval outputs...${NC}"
        rm -rf "$OUTPUT_DIR"/*-workspace 2>/dev/null
        rm -f "$OUTPUT_DIR"/*.result "$OUTPUT_DIR"/*-agent.txt "$OUTPUT_DIR"/*-build.txt "$OUTPUT_DIR"/*-errors.txt "$OUTPUT_DIR"/*-claude.txt 2>/dev/null
        echo "Done."
        echo ""
    fi

    # Detect authentication mode (direct API vs internal gateway)
    detect_auth_mode
    if [[ "$USE_GATEWAY" -eq 1 ]]; then
        echo -e "Auth: ${CYAN}Internal gateway${NC} (iap-auth)"
    else
        echo -e "Auth: ${CYAN}Direct Anthropic API${NC}"
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

        # Start evaluation in background with timeout
        run_with_timeout "$EVAL_TIMEOUT" run_evaluation "$eval_id" "$eval_name" "$eval_query" "$verify_patterns" "$schema_addition" "$negative_patterns" &
        running_pids+=($!)
        running_evals+=("$eval_id")
    done

    # Wait for all remaining jobs
    echo "Waiting for remaining evaluations to complete..."
    for pid in "${running_pids[@]}"; do
        wait "$pid" 2>/dev/null || true
    done

    # Helper: format token count as human-readable (e.g., 31198 -> "31.2K")
    format_tokens() {
        local n="$1"
        if [[ "$n" -ge 1000000 ]]; then
            printf "%.1fM" "$(echo "$n / 1000000" | bc -l)"
        elif [[ "$n" -ge 1000 ]]; then
            printf "%.1fK" "$(echo "$n / 1000" | bc -l)"
        else
            echo "$n"
        fi
    }

    # Collect results into arrays for grouped reporting
    local passed=0 failed=0 one_shot=0 total_run=0
    local total_prompt_tokens=0 total_completion_tokens=0
    local -a success_oneshot=()
    local -a success_retry=()    # "eval_id|attempts|timing"
    local -a failure_list=()     # "eval_id|reason|details"
    local -a token_rows=()       # "eval_id|status|prompt|completion|cost"

    for idx in "${evals_to_run[@]}"; do
        local eval_id=$(jq -r ".[$idx].id" "$EVAL_FILE")
        local eval_name=$(jq -r ".[$idx].name" "$EVAL_FILE")
        local result_file="$OUTPUT_DIR/$eval_id$suffix$backend_suffix.result"
        local tokens_file="$OUTPUT_DIR/$eval_id$suffix$backend_suffix.tokens"
        ((total_run++))

        # Read token counts
        local pt=0 ct=0 cost="0"
        if [[ -f "$tokens_file" ]]; then
            IFS='|' read -r pt ct cost < "$tokens_file"
        fi
        total_prompt_tokens=$((total_prompt_tokens + pt))
        total_completion_tokens=$((total_completion_tokens + ct))

        if [[ -f "$result_file" ]]; then
            local result=$(cat "$result_file")
            local status=$(echo "$result" | cut -d'|' -f1)
            local attempt=$(echo "$result" | cut -d'|' -f3)
            local timing=$(echo "$result" | rev | cut -d'|' -f1 | rev)

            token_rows+=("$eval_id|$status|$pt|$ct|$cost")

            if [[ "$status" == "PASS" ]]; then
                ((passed++))
                if [[ "$attempt" == "1" ]]; then
                    ((one_shot++))
                    success_oneshot+=("$eval_id ($eval_name)")
                else
                    local retry_errors=$(echo "$result" | cut -d'|' -f4)
                    success_retry+=("$eval_id ($eval_name)|$attempt|$timing|$retry_errors")
                fi
            else
                ((failed++))
                local fail_reason=$(echo "$result" | cut -d'|' -f4)
                local error_details=""
                local errors_file="$OUTPUT_DIR/$eval_id$suffix$backend_suffix-errors.txt"
                if [[ -f "$errors_file" ]] && [[ -s "$errors_file" ]]; then
                    error_details=$(cat "$errors_file")
                fi
                failure_list+=("$eval_id ($eval_name)|$fail_reason|$error_details|$timing")
            fi
        else
            ((failed++))
            token_rows+=("$eval_id|TIMEOUT|$pt|$ct|$cost")
            failure_list+=("$eval_id ($eval_name)|timeout|Exceeded ${EVAL_TIMEOUT}s limit|")
        fi
    done

    # Print report
    echo ""
    echo "============================================================"
    echo "REPORT"
    echo "============================================================"
    [[ $USE_SKILL -eq 1 ]] && echo -e "Mode: ${GREEN}WITH SKILL${NC}" || echo -e "Mode: ${BLUE}NO SKILL${NC}"
    echo -e "Backend: ${CYAN}$BACKEND${NC}"
    echo ""

    # --- Successes ---
    echo -e "${GREEN}PASSED: $passed / $total_run${NC}"
    echo ""

    if [[ ${#success_oneshot[@]} -gt 0 ]]; then
        echo -e "  ${GREEN}One-shot ($one_shot):${NC}"
        for entry in "${success_oneshot[@]}"; do
            echo -e "    ${GREEN}✓${NC} $entry"
        done
        echo ""
    fi

    if [[ ${#success_retry[@]} -gt 0 ]]; then
        echo -e "  ${YELLOW}Passed with retries ($(( passed - one_shot ))):${NC}"
        for entry in "${success_retry[@]}"; do
            local name=$(echo "$entry" | cut -d'|' -f1)
            local attempts=$(echo "$entry" | cut -d'|' -f2)
            local timing=$(echo "$entry" | cut -d'|' -f3)
            local retry_errors=$(echo "$entry" | cut -d'|' -f4)
            echo -e "    ${YELLOW}✓${NC} $name — ${YELLOW}$attempts attempts${NC} [$timing]"
            if [[ -n "$retry_errors" ]]; then
                echo -e "      ${CYAN}retry errors: $retry_errors${NC}"
            fi
        done
        echo ""
    fi

    # --- Failures ---
    if [[ ${#failure_list[@]} -gt 0 ]]; then
        echo -e "${RED}FAILED: $failed / $total_run${NC}"
        echo ""
        for entry in "${failure_list[@]}"; do
            local name=$(echo "$entry" | cut -d'|' -f1)
            local reason=$(echo "$entry" | cut -d'|' -f2)
            local details=$(echo "$entry" | cut -d'|' -f3)
            local timing=$(echo "$entry" | cut -d'|' -f4)
            echo -e "  ${RED}✗${NC} $name"
            echo -e "    Reason: ${RED}$reason${NC}"
            if [[ -n "$timing" ]]; then
                echo -e "    Timing: $timing"
            fi
            if [[ -n "$details" ]]; then
                while IFS= read -r line; do
                    echo -e "    ${CYAN}$line${NC}"
                done <<< "$details"
            fi
            echo ""
        done
    fi

    # --- Token Usage ---
    echo "TOKEN USAGE:"
    echo "-----------------"
    printf "  %-40s  %8s  %10s  %12s  %8s\n" "Evaluation" "Status" "Prompt" "Completion" "Cost"
    printf "  %-40s  %8s  %10s  %12s  %8s\n" "$(printf '%0.s─' {1..40})" "$(printf '%0.s─' {1..8})" "$(printf '%0.s─' {1..10})" "$(printf '%0.s─' {1..12})" "$(printf '%0.s─' {1..8})"

    for row in "${token_rows[@]}"; do
        local t_id=$(echo "$row" | cut -d'|' -f1)
        local t_status=$(echo "$row" | cut -d'|' -f2)
        local t_pt=$(echo "$row" | cut -d'|' -f3)
        local t_ct=$(echo "$row" | cut -d'|' -f4)
        local t_cost=$(echo "$row" | cut -d'|' -f5)

        local status_color="$GREEN"
        [[ "$t_status" != "PASS" ]] && status_color="$RED"
        local cost_fmt=$(printf "\$%.2f" "$t_cost")

        printf "  %-40s  " "$t_id"
        echo -ne "${status_color}$(printf '%8s' "$t_status")${NC}"
        printf "  %10s  %12s  %8s\n" "$(format_tokens "$t_pt")" "$(format_tokens "$t_ct")" "$cost_fmt"
    done

    printf "  %-40s  %8s  %10s  %12s  %8s\n" "$(printf '%0.s─' {1..40})" "$(printf '%0.s─' {1..8})" "$(printf '%0.s─' {1..10})" "$(printf '%0.s─' {1..12})" "$(printf '%0.s─' {1..8})"

    local total_tokens=$((total_prompt_tokens + total_completion_tokens))
    printf "  %-40s  %8s  %10s  %12s\n" "TOTAL" "" "$(format_tokens "$total_prompt_tokens")" "$(format_tokens "$total_completion_tokens")"
    echo -e "  Total tokens: ${CYAN}$(format_tokens $total_tokens)${NC} (prompt: $(format_tokens $total_prompt_tokens) + completion: $(format_tokens $total_completion_tokens))"
    echo ""

    echo "============================================================"
    echo -e "Total: $total_run  |  ${GREEN}Passed: $passed${NC}  |  ${GREEN}One-shot: $one_shot${NC}  |  ${RED}Failed: $failed${NC}"
    if [[ $passed -gt 0 ]]; then
        echo -e "One-shot rate: ${GREEN}$(( one_shot * 100 / passed ))%${NC} of passes  |  ${GREEN}$(( one_shot * 100 / total_run ))%${NC} of total"
    fi
    echo -e "Tokens: ${CYAN}$(format_tokens $total_tokens)${NC} (prompt: $(format_tokens $total_prompt_tokens) + completion: $(format_tokens $total_completion_tokens))"
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

    [[ $failed -gt 0 ]] && return 1 || return 0
}

run_compare() {
    echo "============================================================"
    echo "COMPARISON MODE: skill vs no-skill"
    echo "============================================================"
    echo ""

    local backend_suffix=$([[ "$BACKEND" == "crush" ]] && echo "-crush" || echo "")

    # Run with skill
    echo -e "${GREEN}>>> Running WITH skill...${NC}"
    echo ""
    USE_SKILL=1
    export USE_SKILL
    main
    local skill_exit=$?

    echo ""
    echo ""

    # Run without skill
    echo -e "${BLUE}>>> Running WITHOUT skill...${NC}"
    echo ""
    USE_SKILL=0
    export USE_SKILL
    main
    local noskill_exit=$?

    # Build comparison from result files
    echo ""
    echo ""
    echo "============================================================"
    echo "COMPARISON REPORT"
    echo "============================================================"
    echo -e "Backend: ${CYAN}$BACKEND${NC}"
    echo ""

    local eval_count=$(jq length "$EVAL_FILE")

    # Header
    printf "  %-40s  %-18s  %-18s\n" "Evaluation" "With Skill" "Without Skill"
    printf "  %-40s  %-18s  %-18s\n" "$(printf '%0.s─' {1..40})" "$(printf '%0.s─' {1..18})" "$(printf '%0.s─' {1..18})"

    local skill_passed=0 skill_oneshot=0 skill_total=0
    local noskill_passed=0 noskill_oneshot=0 noskill_total=0

    for i in $(seq 0 $((eval_count - 1))); do
        local eval_id=$(jq -r ".[$i].id" "$EVAL_FILE")
        local eval_name=$(jq -r ".[$i].name" "$EVAL_FILE")

        # Filter check
        if [[ -n "$FILTER" && "$eval_id" != *"$FILTER"* && "$eval_name" != *"$FILTER"* ]]; then
            continue
        fi

        local skill_result_file="$OUTPUT_DIR/$eval_id$backend_suffix.result"
        local noskill_result_file="$OUTPUT_DIR/$eval_id-noskill$backend_suffix.result"

        local skill_label noskill_label

        # Parse skill result
        ((skill_total++))
        if [[ -f "$skill_result_file" ]]; then
            local s_result=$(cat "$skill_result_file")
            local s_status=$(echo "$s_result" | cut -d'|' -f1)
            local s_attempt=$(echo "$s_result" | cut -d'|' -f3)
            if [[ "$s_status" == "PASS" ]]; then
                ((skill_passed++))
                if [[ "$s_attempt" == "1" ]]; then
                    ((skill_oneshot++))
                    skill_label="${GREEN}one-shot${NC}"
                else
                    skill_label="${YELLOW}attempt $s_attempt${NC}"
                fi
            else
                local s_reason=$(echo "$s_result" | cut -d'|' -f4)
                skill_label="${RED}FAIL ($s_reason)${NC}"
            fi
        else
            skill_label="${RED}TIMEOUT${NC}"
        fi

        # Parse no-skill result
        ((noskill_total++))
        if [[ -f "$noskill_result_file" ]]; then
            local n_result=$(cat "$noskill_result_file")
            local n_status=$(echo "$n_result" | cut -d'|' -f1)
            local n_attempt=$(echo "$n_result" | cut -d'|' -f3)
            if [[ "$n_status" == "PASS" ]]; then
                ((noskill_passed++))
                if [[ "$n_attempt" == "1" ]]; then
                    ((noskill_oneshot++))
                    noskill_label="${GREEN}one-shot${NC}"
                else
                    noskill_label="${YELLOW}attempt $n_attempt${NC}"
                fi
            else
                local n_reason=$(echo "$n_result" | cut -d'|' -f4)
                noskill_label="${RED}FAIL ($n_reason)${NC}"
            fi
        else
            noskill_label="${RED}TIMEOUT${NC}"
        fi

        # Use fixed-width columns with tput for reliable alignment
        local display_id="$eval_id"
        [[ ${#display_id} -gt 40 ]] && display_id="${display_id:0:37}..."
        printf "  %-40s  " "$display_id"
        # Print skill result (pad to 20 visible chars)
        echo -ne "$skill_label"
        printf "\t"
        echo -e "$noskill_label"
    done

    echo ""
    printf "  %-40s  %-18s  %-18s\n" "$(printf '%0.s─' {1..40})" "$(printf '%0.s─' {1..18})" "$(printf '%0.s─' {1..18})"

    echo -e "  Passed:                                   ${GREEN}$skill_passed / $skill_total${NC}              ${BLUE}$noskill_passed / $noskill_total${NC}"
    echo -e "  One-shot:                                 ${GREEN}$skill_oneshot / $skill_total${NC}              ${BLUE}$noskill_oneshot / $noskill_total${NC}"

    if [[ $skill_total -gt 0 ]]; then
        local skill_pct=$(( skill_oneshot * 100 / skill_total ))
        local noskill_pct=$(( noskill_oneshot * 100 / noskill_total ))
        local delta=$(( skill_pct - noskill_pct ))
        echo ""
        echo -e "  One-shot rate:                            ${GREEN}${skill_pct}%${NC}                  ${BLUE}${noskill_pct}%${NC}"
        if [[ $delta -gt 0 ]]; then
            echo -e "  Skill improvement:                        ${GREEN}+${delta}pp${NC}"
        elif [[ $delta -lt 0 ]]; then
            echo -e "  Skill improvement:                        ${RED}${delta}pp${NC}"
        else
            echo -e "  Skill improvement:                        0pp (no difference)"
        fi
    fi

    echo ""
    echo "Outputs: $OUTPUT_DIR"

    [[ $skill_exit -ne 0 || $noskill_exit -ne 0 ]] && exit 1
    exit 0
}

if [[ $COMPARE -eq 1 ]]; then
    run_compare
else
    main
    exit $?
fi
