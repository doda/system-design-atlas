#!/bin/bash
# run-all-parallel.sh - Run all 100 problems with N parallel Codex workers
#
# Usage: ./scripts/run-all-parallel.sh [PARALLELISM]
# Default parallelism is 10
#
# Bash 3.2 compatible (macOS default)

set -e

PARALLELISM=${1:-10}
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

echo "=========================================="
echo "System Design Atlas - Full Generation"
echo "=========================================="
echo "Parallelism: $PARALLELISM workers"
echo ""

# Create necessary directories
mkdir -p "$PROJECT_DIR/logs"
mkdir -p "$PROJECT_DIR/drafts"
mkdir -p "$PROJECT_DIR/reviewed"

# Parse problems.yaml and extract problem data
parse_problems() {
    local current_slug=""
    local current_title=""
    local current_category=""
    local current_category_dir=""
    local current_description=""
    local in_description=false

    while IFS= read -r line; do
        # Skip comments and empty lines
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${line// }" ]] && continue

        # Check for new problem entry
        if [[ "$line" =~ ^[[:space:]]*-[[:space:]]*slug: ]]; then
            # Output previous problem if we have one
            if [[ -n "$current_slug" ]]; then
                echo "$current_slug|$current_title|$current_category|$current_category_dir|$current_description"
            fi
            current_slug=$(echo "$line" | sed 's/.*slug:[[:space:]]*"\([^"]*\)".*/\1/')
            current_title=""
            current_category=""
            current_category_dir=""
            current_description=""
            in_description=false
        elif [[ "$line" =~ ^[[:space:]]*title: ]]; then
            current_title=$(echo "$line" | sed 's/.*title:[[:space:]]*"\([^"]*\)".*/\1/')
        elif [[ "$line" =~ ^[[:space:]]*category:[[:space:]] ]] && [[ ! "$line" =~ category_dir ]]; then
            current_category=$(echo "$line" | sed 's/.*category:[[:space:]]*"\([^"]*\)".*/\1/')
        elif [[ "$line" =~ ^[[:space:]]*category_dir: ]]; then
            current_category_dir=$(echo "$line" | sed 's/.*category_dir:[[:space:]]*"\([^"]*\)".*/\1/')
        elif [[ "$line" =~ ^[[:space:]]*description: ]]; then
            current_description=$(echo "$line" | sed 's/.*description:[[:space:]]*"\([^"]*\)".*/\1/')
            if [[ -z "$current_description" ]]; then
                in_description=true
                current_description=""
            fi
        elif [[ "$in_description" == true ]]; then
            if [[ "$line" =~ ^[[:space:]]*[a-z_]+: ]] || [[ "$line" =~ ^[[:space:]]*- ]]; then
                in_description=false
            else
                # Append to description
                local desc_line=$(echo "$line" | sed 's/^[[:space:]]*//')
                if [[ -n "$current_description" ]]; then
                    current_description="$current_description $desc_line"
                else
                    current_description="$desc_line"
                fi
            fi
        fi
    done < "$PROJECT_DIR/problems.yaml"

    # Output last problem
    if [[ -n "$current_slug" ]]; then
        echo "$current_slug|$current_title|$current_category|$current_category_dir|$current_description"
    fi
}

# Count running jobs (bash 3.2 compatible)
count_running() {
    local count=0
    for pid in "${pids[@]}"; do
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            count=$((count + 1))
        fi
    done
    echo $count
}

# Reap finished jobs and report status
reap_finished() {
    local new_pids=()
    local new_slugs=()
    local new_titles=()

    for i in "${!pids[@]}"; do
        local pid="${pids[$i]}"
        local slug="${slugs[$i]}"
        local title="${titles[$i]}"

        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            # Still running
            new_pids+=("$pid")
            new_slugs+=("$slug")
            new_titles+=("$title")
        elif [[ -n "$pid" ]]; then
            # Finished - check exit code
            if wait "$pid" 2>/dev/null; then
                echo "[DONE] $title"
                COMPLETED=$((COMPLETED + 1))
            else
                echo "[FAIL] $title (see logs/$slug.log)"
                FAILED=$((FAILED + 1))
            fi
        fi
    done

    pids=("${new_pids[@]}")
    slugs=("${new_slugs[@]}")
    titles=("${new_titles[@]}")
}

# Get all problems
echo "Parsing problems.yaml..."
PROBLEMS=()
while IFS= read -r problem; do
    PROBLEMS+=("$problem")
done < <(parse_problems)

TOTAL=${#PROBLEMS[@]}
echo "Found $TOTAL problems"
echo ""

# Track progress
COMPLETED=0
FAILED=0
SKIPPED=0

# Arrays for tracking jobs (bash 3.2 compatible - indexed arrays only)
pids=()
slugs=()
titles=()

# Process problems
echo "Starting generation with $PARALLELISM parallel workers..."
echo ""

idx=0
for problem in "${PROBLEMS[@]}"; do
    idx=$((idx + 1))

    IFS='|' read -r slug title category category_dir description <<< "$problem"
    solution_file="$PROJECT_DIR/solutions/$category_dir/$slug.md"

    # Skip if already exists
    if [[ -f "$solution_file" ]]; then
        echo "[SKIP] [$idx/$TOTAL] $title"
        SKIPPED=$((SKIPPED + 1))
        continue
    fi

    # Wait until we have a free slot
    while true; do
        reap_finished
        running=$(count_running)
        if [[ $running -lt $PARALLELISM ]]; then
            break
        fi
        sleep 1
    done

    # Start the job in background
    (
        mkdir -p "$PROJECT_DIR/solutions/$category_dir"
        "$SCRIPT_DIR/generate-solution.sh" \
            "$slug" \
            "$title" \
            "$category" \
            "$category_dir" \
            "$description" \
            > "$PROJECT_DIR/logs/$slug.log" 2>&1
        exit $?
    ) &

    pids+=($!)
    slugs+=("$slug")
    titles+=("[$idx/$TOTAL] $title")
    echo "[START] [$idx/$TOTAL] $title"
done

# Wait for all remaining jobs
echo ""
echo "Waiting for remaining jobs to complete..."
while true; do
    reap_finished
    running=$(count_running)
    if [[ $running -eq 0 ]]; then
        break
    fi
    sleep 2
done

echo ""
echo "=========================================="
echo "Generation Complete"
echo "=========================================="
echo "Total: $TOTAL"
echo "Completed: $COMPLETED"
echo "Skipped: $SKIPPED"
echo "Failed: $FAILED"
echo ""
echo "Solutions: $PROJECT_DIR/solutions/"
echo "Logs: $PROJECT_DIR/logs/"
