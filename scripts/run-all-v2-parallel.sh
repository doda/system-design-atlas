#!/bin/bash
# run-all-v2-parallel.sh - Run v2 pipeline on all problems in parallel
#
# Usage: ./scripts/run-all-v2-parallel.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

cd "$PROJECT_DIR"

echo "=========================================="
echo "Running v2 pipeline on all 100 problems"
echo "Launching all in parallel..."
echo "=========================================="

# Create output directories
mkdir -p drafts-v2 challenges solutions-v2 logs/v2

# Extract problems from YAML and create a jobs file
awk '
/^  - slug:/ { slug = $3; gsub(/"/, "", slug) }
/^    title:/ { title = substr($0, index($0, ":")+2); gsub(/^"/, "", title); gsub(/"$/, "", title) }
/^    category:/ && !/category_dir/ { category = substr($0, index($0, ":")+2); gsub(/^"/, "", category); gsub(/"$/, "", category) }
/^    category_dir:/ { category_dir = $2; gsub(/"/, "", category_dir) }
/^    description:/ {
    description = substr($0, index($0, ":")+2)
    gsub(/^"/, "", description)
    gsub(/"$/, "", description)
    print slug "\t" title "\t" category "\t" category_dir "\t" description
}
' problems.yaml > /tmp/v2_jobs.tsv

TOTAL=$(wc -l < /tmp/v2_jobs.tsv | tr -d ' ')
echo "Found $TOTAL problems"
echo ""

# Create a temp dir for status files
STATUS_DIR=$(mktemp -d)
trap "rm -rf $STATUS_DIR /tmp/v2_jobs.tsv" EXIT

# Launch all jobs in background
job_num=0
while IFS=$'\t' read -r slug title category category_dir description; do
    job_num=$((job_num + 1))

    (
        log_file="logs/v2/${slug}.log"
        start=$(date +%s)

        if ./scripts/generate-solution-v2.sh "$slug" "$title" "$category" "$category_dir" "$description" > "$log_file" 2>&1; then
            end=$(date +%s)
            duration=$((end - start))
            echo "success:${duration}" > "$STATUS_DIR/${slug}.status"
        else
            echo "failed:0" > "$STATUS_DIR/${slug}.status"
        fi
    ) &

    # Small stagger for initial launches
    if [ $job_num -le 20 ]; then
        sleep 0.2
    fi
done < /tmp/v2_jobs.tsv

echo "Launched $job_num jobs"
echo "Monitoring progress..."
echo ""

# Monitor progress
while true; do
    completed=$(ls -1 "$STATUS_DIR"/*.status 2>/dev/null | wc -l | tr -d ' ')
    if [ "$completed" -ge "$TOTAL" ]; then
        break
    fi
    echo -ne "\rCompleted: $completed / $TOTAL"
    sleep 5
done

echo -e "\rCompleted: $TOTAL / $TOTAL"
echo ""

# Collect results
SUCCEEDED=0
FAILED=0

echo "Results:"
for status_file in "$STATUS_DIR"/*.status; do
    slug=$(basename "$status_file" .status)
    status=$(cat "$status_file" | cut -d: -f1)
    duration=$(cat "$status_file" | cut -d: -f2)

    if [ "$status" = "success" ]; then
        SUCCEEDED=$((SUCCEEDED + 1))
        echo "✓ $slug (${duration}s)"
    else
        FAILED=$((FAILED + 1))
        echo "✗ $slug"
    fi
done

echo ""
echo "=========================================="
echo "Completed: $SUCCEEDED succeeded, $FAILED failed"
echo "=========================================="
