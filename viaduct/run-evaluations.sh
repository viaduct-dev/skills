#!/bin/bash
#
# Simple evaluation runner using Claude Code CLI
#
# Usage:
#   ./run-evaluations.sh [eval-id]
#
# This runs each evaluation query through Claude Code with the skill loaded
# and saves the output for manual review.
#

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
EVAL_FILE="$SCRIPT_DIR/evaluations.json"
OUTPUT_DIR="$SCRIPT_DIR/.eval-results"
WORKSPACE_DIR="$SCRIPT_DIR/.eval-workspace"

mkdir -p "$OUTPUT_DIR"
mkdir -p "$WORKSPACE_DIR"

# Check dependencies
if ! command -v jq &> /dev/null; then
    echo "Error: jq is required. Install with: brew install jq"
    exit 1
fi

if ! command -v claude &> /dev/null; then
    echo "Error: claude CLI is required."
    exit 1
fi

# Get evaluation count
EVAL_COUNT=$(jq length "$EVAL_FILE")
FILTER="${1:-}"

echo "Viaduct Skill Evaluation Runner"
echo "================================"
echo "Evaluations file: $EVAL_FILE"
echo "Output directory: $OUTPUT_DIR"
echo ""

PASSED=0
FAILED=0

for i in $(seq 0 $((EVAL_COUNT - 1))); do
    EVAL_ID=$(jq -r ".[$i].id" "$EVAL_FILE")
    EVAL_NAME=$(jq -r ".[$i].name" "$EVAL_FILE")
    EVAL_QUERY=$(jq -r ".[$i].query" "$EVAL_FILE")

    # Skip if filter provided and doesn't match
    if [[ -n "$FILTER" && "$EVAL_ID" != "$FILTER" && "$EVAL_NAME" != *"$FILTER"* ]]; then
        continue
    fi

    echo ""
    echo "============================================================"
    echo "Running: $EVAL_ID - $EVAL_NAME"
    echo "============================================================"
    echo "Query: $EVAL_QUERY"
    echo ""

    OUTPUT_FILE="$OUTPUT_DIR/$EVAL_ID.txt"

    # Run Claude Code with the skill
    # --print flag outputs result without interactive mode
    # --dangerously-skip-permissions skips approval prompts
    if claude --print \
              --dangerously-skip-permissions \
              --allowedTools "Read,Glob,Grep,Write,Edit" \
              -p "$EVAL_QUERY" \
              "$WORKSPACE_DIR" > "$OUTPUT_FILE" 2>&1; then
        echo "✅ Completed (output saved)"
        ((PASSED++)) || true
    else
        echo "❌ Failed (see output file)"
        ((FAILED++)) || true
    fi

    echo "Output: $OUTPUT_FILE"

    # Show expected behaviors for manual checking
    echo ""
    echo "Expected behaviors to verify:"
    jq -r ".[$i].expected_behavior[]" "$EVAL_FILE" | while read -r behavior; do
        echo "  [ ] $behavior"
    done
done

echo ""
echo "============================================================"
echo "SUMMARY"
echo "============================================================"
echo "Completed: $PASSED"
echo "Failed: $FAILED"
echo ""
echo "Review outputs in: $OUTPUT_DIR"
echo ""
echo "To check an evaluation result:"
echo "  cat $OUTPUT_DIR/eval-01-field-resolver.txt"
