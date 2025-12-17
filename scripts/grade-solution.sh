#!/bin/bash
# grade-solution.sh - Grade a single solution using Codex
#
# Usage: ./scripts/grade-solution.sh <solution_file> <output_file>

set -e

SOLUTION_FILE="$1"
OUTPUT_FILE="$2"

if [[ -z "$SOLUTION_FILE" || -z "$OUTPUT_FILE" ]]; then
    echo "Usage: $0 <solution_file> <output_file>"
    exit 1
fi

SLUG=$(basename "$SOLUTION_FILE" .md)
CONTENT=$(cat "$SOLUTION_FILE")

GRADE_PROMPT="You are a senior systems architect reviewing a system design document.

Grade this solution on three dimensions (1-10 scale):

1. **Strength** (1-10): How technically sound, complete, and production-ready is the design?
   - Does it address scalability, reliability, and failure modes?
   - Are the trade-offs well-reasoned?
   - Would this actually work at scale?

2. **Interestingness** (1-10): How engaging and educational is the content?
   - Does it teach useful concepts?
   - Are there insights that aren't obvious?
   - Would an engineer learn something valuable?

3. **Novelty** (1-10): How unique or creative is the approach?
   - Does it go beyond textbook solutions?
   - Are there clever simplifications or unconventional choices?
   - Does it challenge common assumptions?

Also note any major issues or particularly strong aspects.

Output ONLY valid JSON in this exact format:
{
  \"slug\": \"$SLUG\",
  \"strength\": <1-10>,
  \"interestingness\": <1-10>,
  \"novelty\": <1-10>,
  \"overall\": <average of three scores, 1 decimal>,
  \"summary\": \"<2-3 sentence summary of the design>\",
  \"strengths\": [\"<strength 1>\", \"<strength 2>\"],
  \"weaknesses\": [\"<weakness 1>\", \"<weakness 2>\"],
  \"verdict\": \"<one of: exceptional, strong, adequate, weak>\"
}

---

## Solution to Grade

$CONTENT"

codex exec \
    -m "gpt-5.2" \
    --full-auto \
    --skip-git-repo-check \
    -o "$OUTPUT_FILE" \
    "$GRADE_PROMPT"

echo "Graded: $SLUG"
