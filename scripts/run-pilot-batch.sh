#!/bin/bash
# run-pilot-batch.sh - Run the pilot batch of 5 problems in parallel
#
# This script runs generate+review+simplify for 5 problems concurrently.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

echo "=========================================="
echo "System Design Atlas - Pilot Batch (5)"
echo "=========================================="
echo "Mode: Parallel (all 5 concurrent)"
echo ""

# Define the 5 pilot problems
declare -a PROBLEMS=(
    "distributed-unique-id-generator|Distributed Unique ID Generator|Foundational Infrastructure|01-foundational-infrastructure|Design a Snowflake-like service with time-ordering guarantees, clock skew protection, and multi-region failure modes."
    "global-rate-limiter|Global Rate Limiter|Foundational Infrastructure|01-foundational-infrastructure|Design a rate limiter (per user/IP/API key) that works across extensive geographic regions with low coordination overhead and latency."
    "url-shortener|URL Shortener & Link Management|Foundational Infrastructure|01-foundational-infrastructure|Design a system handling custom aliases, aggressive expiration policies, abuse prevention, and global low-latency reads."
    "distributed-lock-service|Distributed Lock Service|Foundational Infrastructure|01-foundational-infrastructure|Design a coordination service (like Chubby/ZooKeeper) focusing on lease management, fencing tokens, and client failure detection."
    "task-scheduler-batch|Task Scheduler (Batch)|Foundational Infrastructure|01-foundational-infrastructure|Design a distributed job scheduler supporting priority queues, delayed execution, retries, and multi-tenant isolation."
)

run_problem() {
    local problem_str="$1"
    local idx="$2"

    IFS='|' read -r slug title category category_dir description <<< "$problem_str"

    echo "[$((idx+1))/5] Starting: $title"

    "$SCRIPT_DIR/generate-solution.sh" \
        "$slug" \
        "$title" \
        "$category" \
        "$category_dir" \
        "$description" > "$PROJECT_DIR/logs/$slug.log" 2>&1

    echo "[$((idx+1))/5] Completed: $title"
}

# Create logs directory
mkdir -p "$PROJECT_DIR/logs"

# Run all problems in parallel
pids=()
for i in "${!PROBLEMS[@]}"; do
    run_problem "${PROBLEMS[$i]}" "$i" &
    pids+=($!)
done

echo "Started ${#pids[@]} parallel jobs..."
echo "Logs: $PROJECT_DIR/logs/"
echo ""

# Wait for all to complete
failed=0
for i in "${!pids[@]}"; do
    if ! wait ${pids[$i]}; then
        echo "Job $((i+1)) failed"
        ((failed++))
    fi
done

echo ""
echo "=========================================="
echo "Pilot batch complete!"
echo "=========================================="
echo ""
echo "Failed: $failed/5"
echo ""
echo "Drafts:"
ls -la "$PROJECT_DIR/drafts/" 2>/dev/null || echo "  (none)"
echo ""
echo "Reviewed:"
ls -la "$PROJECT_DIR/reviewed/" 2>/dev/null || echo "  (none)"
echo ""
echo "Solutions:"
ls -la "$PROJECT_DIR/solutions/01-foundational-infrastructure/" 2>/dev/null || echo "  (none)"
