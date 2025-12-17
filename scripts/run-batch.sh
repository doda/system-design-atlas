#!/bin/bash
# run-batch.sh - Run generation + review for multiple problems
#
# Usage:
#   ./scripts/run-batch.sh              # Run all problems in problems.yaml
#   ./scripts/run-batch.sh --parallel 3 # Run 3 problems in parallel
#   ./scripts/run-batch.sh --limit 5    # Only run first 5 problems
#
# Note: Each problem runs generate+review sequentially, but multiple problems
# can be processed in parallel.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Default values
PARALLEL=1
LIMIT=0  # 0 means no limit

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --parallel|-p)
            PARALLEL="$2"
            shift 2
            ;;
        --limit|-l)
            LIMIT="$2"
            shift 2
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

echo "=========================================="
echo "System Design Atlas - Batch Generator"
echo "=========================================="
echo "Parallel jobs: $PARALLEL"
echo "Limit: ${LIMIT:-none}"
echo ""

# Check for yq (YAML parser)
if ! command -v yq &> /dev/null; then
    echo "Error: yq is required but not installed."
    echo "Install with: brew install yq"
    exit 1
fi

PROBLEMS_FILE="$PROJECT_DIR/problems.yaml"

# Extract problems from YAML
COUNT=$(yq '.problems | length' "$PROBLEMS_FILE")

if [[ $LIMIT -gt 0 && $LIMIT -lt $COUNT ]]; then
    COUNT=$LIMIT
fi

echo "Processing $COUNT problems..."
echo ""

# Function to process a single problem
process_problem() {
    local idx=$1

    local slug=$(yq ".problems[$idx].slug" "$PROBLEMS_FILE")
    local title=$(yq ".problems[$idx].title" "$PROBLEMS_FILE")
    local category=$(yq ".problems[$idx].category" "$PROBLEMS_FILE")
    local category_dir=$(yq ".problems[$idx].category_dir" "$PROBLEMS_FILE")
    local description=$(yq ".problems[$idx].description" "$PROBLEMS_FILE")

    "$SCRIPT_DIR/generate-solution.sh" \
        "$slug" \
        "$title" \
        "$category" \
        "$category_dir" \
        "$description"
}

export -f process_problem
export SCRIPT_DIR
export PROBLEMS_FILE

# Run problems with parallelism
if [[ $PARALLEL -eq 1 ]]; then
    # Sequential execution
    for ((i=0; i<COUNT; i++)); do
        process_problem $i
    done
else
    # Parallel execution using GNU parallel or background jobs
    if command -v parallel &> /dev/null; then
        seq 0 $((COUNT-1)) | parallel -j "$PARALLEL" process_problem {}
    else
        # Fallback to background jobs with wait
        running=0
        for ((i=0; i<COUNT; i++)); do
            process_problem $i &
            ((running++))

            if [[ $running -ge $PARALLEL ]]; then
                wait -n
                ((running--))
            fi
        done
        wait
    fi
fi

echo ""
echo "=========================================="
echo "Batch complete!"
echo "=========================================="
echo ""
echo "Solutions saved to: $PROJECT_DIR/solutions/"
ls -la "$PROJECT_DIR/solutions/"
