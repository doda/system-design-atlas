#!/bin/bash
# generate-solution.sh - Generate, review, simplify, and validate a single system design solution
#
# Usage: ./scripts/generate-solution.sh <slug> <title> <category> <category_dir> <description>
#
# Four passes:
#   1. Generate: Create initial comprehensive draft
#   2. Review: Improve technical accuracy and completeness
#   3. Simplify: Make architecture and document concise
#   4. Validate: Check and fix Mermaid diagrams

set -e

SLUG="$1"
TITLE="$2"
CATEGORY="$3"
CATEGORY_DIR="$4"
DESCRIPTION="$5"

if [[ -z "$SLUG" || -z "$TITLE" || -z "$CATEGORY" || -z "$CATEGORY_DIR" || -z "$DESCRIPTION" ]]; then
    echo "Usage: $0 <slug> <title> <category> <category_dir> <description>"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

DRAFT_DIR="$PROJECT_DIR/drafts"
REVIEWED_DIR="$PROJECT_DIR/reviewed"
SOLUTION_DIR="$PROJECT_DIR/solutions/$CATEGORY_DIR"
PROMPTS_DIR="$PROJECT_DIR/prompts"

# Ensure directories exist
mkdir -p "$DRAFT_DIR" "$REVIEWED_DIR" "$SOLUTION_DIR"

DRAFT_FILE="$DRAFT_DIR/$SLUG.md"
REVIEWED_FILE="$REVIEWED_DIR/$SLUG.md"
SOLUTION_FILE="$SOLUTION_DIR/$SLUG.md"

MODEL="gpt-5.2"

echo "=========================================="
echo "Generating: $TITLE"
echo "=========================================="

# Read system prompts
GENERATE_PROMPT=$(cat "$PROMPTS_DIR/system-generate.md")
REVIEW_PROMPT=$(cat "$PROMPTS_DIR/system-review.md")
SIMPLIFY_PROMPT=$(cat "$PROMPTS_DIR/system-simplify.md")

# ============================================================================
# Pass 1: Generate Draft
# ============================================================================
echo ""
echo "[Pass 1/4] Generating initial draft..."
echo ""

FULL_GENERATE_PROMPT="$GENERATE_PROMPT

---

## Problem to Solve

**Title**: $TITLE
**Category**: $CATEGORY

**Problem Statement**:
$DESCRIPTION

Generate the complete system design document now."

codex exec \
    -m "$MODEL" \
    --full-auto \
    --skip-git-repo-check \
    -o "$DRAFT_FILE" \
    "$FULL_GENERATE_PROMPT"

echo ""
echo "[Pass 1/4] Draft saved to: $DRAFT_FILE"

# ============================================================================
# Pass 2: Review and Improve
# ============================================================================
echo ""
echo "[Pass 2/4] Reviewing and improving draft..."
echo ""

DRAFT_CONTENT=$(cat "$DRAFT_FILE")

FULL_REVIEW_PROMPT="$REVIEW_PROMPT

---

## Draft to Review

$DRAFT_CONTENT

---

Output the complete, improved document now."

codex exec \
    -m "$MODEL" \
    --full-auto \
    --skip-git-repo-check \
    -o "$REVIEWED_FILE" \
    "$FULL_REVIEW_PROMPT"

echo ""
echo "[Pass 2/4] Reviewed version saved to: $REVIEWED_FILE"

# ============================================================================
# Pass 3: Simplify
# ============================================================================
echo ""
echo "[Pass 3/4] Simplifying architecture..."
echo ""

REVIEWED_CONTENT=$(cat "$REVIEWED_FILE")

FULL_SIMPLIFY_PROMPT="$SIMPLIFY_PROMPT

---

## Document to Simplify

$REVIEWED_CONTENT

---

Output the complete, simplified document now."

codex exec \
    -m "$MODEL" \
    --full-auto \
    --skip-git-repo-check \
    -o "$SOLUTION_FILE" \
    "$FULL_SIMPLIFY_PROMPT"

echo ""
echo "[Pass 3/4] Simplified version saved to: $SOLUTION_FILE"

# ============================================================================
# Pass 4: Validate and Fix Mermaid Diagrams
# ============================================================================
echo ""
echo "[Pass 4/4] Validating Mermaid diagrams..."
echo ""

# Check if mermaid-cli is available
MMDC="$PROJECT_DIR/frontend/node_modules/.bin/mmdc"
if [[ ! -x "$MMDC" ]]; then
    echo "Warning: mermaid-cli not found, skipping validation"
else
    # Extract and validate mermaid blocks
    TEMP_DIR=$(mktemp -d)
    trap "rm -rf $TEMP_DIR" EXIT

    ERRORS=""
    block_num=0
    in_mermaid=false
    block_content=""

    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" == '```mermaid' ]]; then
            in_mermaid=true
            block_content=""
            continue
        fi

        if [[ "$in_mermaid" == true && "$line" == '```' ]]; then
            in_mermaid=false
            ((block_num++))

            # Write block to temp file and validate
            temp_file="$TEMP_DIR/block_${block_num}.mmd"
            echo "$block_content" > "$temp_file"

            if ! $MMDC -i "$temp_file" -o "$TEMP_DIR/out.svg" 2>/dev/null; then
                error_msg=$($MMDC -i "$temp_file" -o "$TEMP_DIR/out.svg" 2>&1 | head -3)
                ERRORS="$ERRORS
--- Block $block_num ---
$block_content
--- Error ---
$error_msg
"
            fi
            block_content=""
            continue
        fi

        if [[ "$in_mermaid" == true ]]; then
            if [[ -n "$block_content" ]]; then
                block_content="$block_content"$'\n'"$line"
            else
                block_content="$line"
            fi
        fi
    done < "$SOLUTION_FILE"

    if [[ -n "$ERRORS" ]]; then
        echo "Found invalid Mermaid diagrams, asking Codex to fix..."

        SOLUTION_CONTENT=$(cat "$SOLUTION_FILE")

        FIX_PROMPT="The following Mermaid diagrams in this document have syntax errors:

$ERRORS

Fix ALL the Mermaid diagrams in the document. Common fixes:
- Quote labels with special characters: A[\"Label (with parens)\"]
- Use short labels (2-4 words max)
- Remove <br/> tags, use simple text
- Ensure valid flowchart/graph/sequenceDiagram syntax

Output the complete fixed document (the entire markdown file, not just the diagrams).

---

$SOLUTION_CONTENT"

        codex exec \
            -m "$MODEL" \
            --full-auto \
            --skip-git-repo-check \
            -o "$SOLUTION_FILE" \
            "$FIX_PROMPT"

        echo "[Pass 4/4] Mermaid diagrams fixed"
    else
        echo "[Pass 4/4] All Mermaid diagrams valid"
    fi
fi

echo ""
echo "=========================================="
echo "Completed: $TITLE"
echo "=========================================="
