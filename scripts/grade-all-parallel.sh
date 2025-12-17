#!/bin/bash
# grade-all-parallel.sh - Grade all solutions with N parallel Codex workers
#
# Usage: ./scripts/grade-all-parallel.sh [PARALLELISM]
# Default parallelism is 30

set -e

PARALLELISM=${1:-30}
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

echo "=========================================="
echo "System Design Atlas - Solution Grading"
echo "=========================================="
echo "Parallelism: $PARALLELISM workers"
echo ""

# Create output directory
GRADES_DIR="$PROJECT_DIR/grades"
mkdir -p "$GRADES_DIR"

# Find all solutions
SOLUTIONS=()
for f in "$PROJECT_DIR"/solutions/**/*.md; do
    if [[ -f "$f" ]]; then
        SOLUTIONS+=("$f")
    fi
done

TOTAL=${#SOLUTIONS[@]}
echo "Found $TOTAL solutions to grade"
echo ""

# Track progress
COMPLETED=0
FAILED=0

# Arrays for tracking jobs (bash 3.2 compatible)
pids=()
slugs=()

# Count running jobs
count_running() {
    local count=0
    for pid in "${pids[@]}"; do
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            count=$((count + 1))
        fi
    done
    echo $count
}

# Reap finished jobs
reap_finished() {
    local new_pids=()
    local new_slugs=()

    for i in "${!pids[@]}"; do
        local pid="${pids[$i]}"
        local slug="${slugs[$i]}"

        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            new_pids+=("$pid")
            new_slugs+=("$slug")
        elif [[ -n "$pid" ]]; then
            if wait "$pid" 2>/dev/null; then
                echo "[DONE] $slug"
                COMPLETED=$((COMPLETED + 1))
            else
                echo "[FAIL] $slug"
                FAILED=$((FAILED + 1))
            fi
        fi
    done

    pids=("${new_pids[@]}")
    slugs=("${new_slugs[@]}")
}

# Process solutions
echo "Starting grading with $PARALLELISM parallel workers..."
echo ""

idx=0
for solution in "${SOLUTIONS[@]}"; do
    idx=$((idx + 1))
    slug=$(basename "$solution" .md)
    output_file="$GRADES_DIR/$slug.json"

    # Skip if already graded
    if [[ -f "$output_file" ]]; then
        echo "[SKIP] [$idx/$TOTAL] $slug"
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

    # Start the grading job
    (
        "$SCRIPT_DIR/grade-solution.sh" "$solution" "$output_file" > "$GRADES_DIR/$slug.log" 2>&1
        exit $?
    ) &

    pids+=($!)
    slugs+=("$slug")
    echo "[START] [$idx/$TOTAL] $slug"
done

# Wait for remaining jobs
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
echo "Grading Complete"
echo "=========================================="
echo "Total: $TOTAL"
echo "Completed: $COMPLETED"
echo "Failed: $FAILED"
echo ""

# Combine all grades into a report
echo "Generating report..."

REPORT_FILE="$PROJECT_DIR/grades/REPORT.md"

cat > "$REPORT_FILE" << 'EOF'
# System Design Atlas - Solution Grades

Graded by AI on strength, interestingness, and novelty (1-10 scale).

| Solution | Strength | Interest | Novelty | Overall | Verdict |
|----------|----------|----------|---------|---------|---------|
EOF

# Sort grades by overall score descending
for grade_file in "$GRADES_DIR"/*.json; do
    if [[ -f "$grade_file" ]]; then
        # Extract fields from JSON (basic parsing)
        slug=$(grep -o '"slug"[[:space:]]*:[[:space:]]*"[^"]*"' "$grade_file" | sed 's/.*"\([^"]*\)"$/\1/' | head -1)
        strength=$(grep -o '"strength"[[:space:]]*:[[:space:]]*[0-9]*' "$grade_file" | sed 's/.*: *//' | head -1)
        interest=$(grep -o '"interestingness"[[:space:]]*:[[:space:]]*[0-9]*' "$grade_file" | sed 's/.*: *//' | head -1)
        novelty=$(grep -o '"novelty"[[:space:]]*:[[:space:]]*[0-9]*' "$grade_file" | sed 's/.*: *//' | head -1)
        overall=$(grep -o '"overall"[[:space:]]*:[[:space:]]*[0-9.]*' "$grade_file" | sed 's/.*: *//' | head -1)
        verdict=$(grep -o '"verdict"[[:space:]]*:[[:space:]]*"[^"]*"' "$grade_file" | sed 's/.*"\([^"]*\)"$/\1/' | head -1)

        if [[ -n "$slug" && -n "$overall" ]]; then
            echo "$overall|$slug|$strength|$interest|$novelty|$verdict"
        fi
    fi
done | sort -t'|' -k1 -rn | while IFS='|' read -r overall slug strength interest novelty verdict; do
    echo "| $slug | $strength | $interest | $novelty | $overall | $verdict |" >> "$REPORT_FILE"
done

# Add summary statistics
cat >> "$REPORT_FILE" << 'EOF'

## Summary Statistics

EOF

# Calculate averages (basic)
total_strength=0
total_interest=0
total_novelty=0
count=0

for grade_file in "$GRADES_DIR"/*.json; do
    if [[ -f "$grade_file" ]]; then
        s=$(grep -o '"strength"[[:space:]]*:[[:space:]]*[0-9]*' "$grade_file" | sed 's/.*: *//' | head -1)
        i=$(grep -o '"interestingness"[[:space:]]*:[[:space:]]*[0-9]*' "$grade_file" | sed 's/.*: *//' | head -1)
        n=$(grep -o '"novelty"[[:space:]]*:[[:space:]]*[0-9]*' "$grade_file" | sed 's/.*: *//' | head -1)
        if [[ -n "$s" && -n "$i" && -n "$n" ]]; then
            total_strength=$((total_strength + s))
            total_interest=$((total_interest + i))
            total_novelty=$((total_novelty + n))
            count=$((count + 1))
        fi
    fi
done

if [[ $count -gt 0 ]]; then
    avg_s=$(echo "scale=1; $total_strength / $count" | bc)
    avg_i=$(echo "scale=1; $total_interest / $count" | bc)
    avg_n=$(echo "scale=1; $total_novelty / $count" | bc)

    echo "- **Solutions graded**: $count" >> "$REPORT_FILE"
    echo "- **Average Strength**: $avg_s / 10" >> "$REPORT_FILE"
    echo "- **Average Interestingness**: $avg_i / 10" >> "$REPORT_FILE"
    echo "- **Average Novelty**: $avg_n / 10" >> "$REPORT_FILE"
fi

echo ""
echo "Report saved to: $REPORT_FILE"
echo "Individual grades in: $GRADES_DIR/"
