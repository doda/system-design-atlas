#!/bin/bash
# generate-solution-v2.sh - Generate solutions with elegance-focused pipeline
#
# Usage: ./scripts/generate-solution-v2.sh <slug> <title> <category> <category_dir> <description>
#
# Pipeline:
#   1. Generate: Create design with elegance mindset
#   2. Challenge: Constructive critic finds improvements
#   3. Refine: Incorporate feedback + simplify
#   4. Validate: Check Mermaid diagrams

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

DRAFT_DIR="$PROJECT_DIR/drafts-v2"
CHALLENGE_DIR="$PROJECT_DIR/challenges"
SOLUTION_DIR="$PROJECT_DIR/solutions-v2/$CATEGORY_DIR"
PROMPTS_DIR="$PROJECT_DIR/prompts/v2"

mkdir -p "$DRAFT_DIR" "$CHALLENGE_DIR" "$SOLUTION_DIR"

DRAFT_FILE="$DRAFT_DIR/$SLUG.md"
CHALLENGE_FILE="$CHALLENGE_DIR/$SLUG.md"
SOLUTION_FILE="$SOLUTION_DIR/$SLUG.md"

MODEL="gpt-5.2"

echo "=========================================="
echo "Generating (v2): $TITLE"
echo "=========================================="

# Read prompts
GENERATE_PROMPT=$(cat "$PROMPTS_DIR/system-generate.md")
CHALLENGE_PROMPT=$(cat "$PROMPTS_DIR/system-challenge.md")
SIMPLIFY_PROMPT=$(cat "$PROMPTS_DIR/system-simplify.md")

# ============================================================================
# Pass 1: Generate with Elegance Mindset
# ============================================================================
echo ""
echo "[Pass 1/4] Generating initial design..."
echo ""

FULL_GENERATE_PROMPT="$GENERATE_PROMPT

---

## Problem to Solve

**Title**: $TITLE
**Category**: $CATEGORY

**Problem Statement**:
$DESCRIPTION

Generate the system design document now."

codex exec \
    -m "$MODEL" \
    --full-auto \
    --skip-git-repo-check \
    -o "$DRAFT_FILE" \
    "$FULL_GENERATE_PROMPT"

echo "[Pass 1/4] Draft saved to: $DRAFT_FILE"

# ============================================================================
# Pass 2: Challenge the Design
# ============================================================================
echo ""
echo "[Pass 2/4] Challenging the design..."
echo ""

DRAFT_CONTENT=$(cat "$DRAFT_FILE")

FULL_CHALLENGE_PROMPT="$CHALLENGE_PROMPT

---

## Design to Challenge

$DRAFT_CONTENT

---

Review this design constructively. Find simplification opportunities and stress-test the failure modes."

codex exec \
    -m "$MODEL" \
    --full-auto \
    --skip-git-repo-check \
    -o "$CHALLENGE_FILE" \
    "$FULL_CHALLENGE_PROMPT"

echo "[Pass 2/4] Challenge saved to: $CHALLENGE_FILE"

# ============================================================================
# Pass 3: Refine - Incorporate Feedback + Simplify
# ============================================================================
echo ""
echo "[Pass 3/4] Refining design..."
echo ""

CHALLENGE_CONTENT=$(cat "$CHALLENGE_FILE")

REFINE_PROMPT="$SIMPLIFY_PROMPT

---

## Original Design

$DRAFT_CONTENT

---

## Critique to Address

$CHALLENGE_CONTENT

---

## Your Task

Produce the **final, elegant design** that:
1. Incorporates valid simplifications from the critique
2. Addresses failure scenarios raised
3. Removes unnecessary complexity
4. Remains practical and buildable by a small team

The result should make readers think \"that's surprisingly simple\" not \"very thorough.\"

Output the complete, final markdown document."

codex exec \
    -m "$MODEL" \
    --full-auto \
    --skip-git-repo-check \
    -o "$SOLUTION_FILE" \
    "$REFINE_PROMPT"

echo "[Pass 3/4] Refined design saved to: $SOLUTION_FILE"

# ============================================================================
# Pass 4: Validate Mermaid Diagrams
# ============================================================================
echo ""
echo "[Pass 4/4] Validating Mermaid diagrams..."
echo ""

MMDC="$PROJECT_DIR/frontend/node_modules/.bin/mmdc"
if [[ ! -x "$MMDC" ]]; then
    echo "Warning: mermaid-cli not found, skipping validation"
else
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
        echo "Found invalid Mermaid diagrams, fixing..."

        SOLUTION_CONTENT=$(cat "$SOLUTION_FILE")

        FIX_PROMPT="Fix these Mermaid syntax errors:

$ERRORS

Common fixes:
- Quote labels with special characters: A[\"Label (with parens)\"]
- Use short labels (2-4 words max)
- Remove HTML tags
- Keep diagrams simple (max 8 nodes)

Output the complete fixed document.

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
echo "Completed (v2): $TITLE"
echo "=========================================="
echo "Draft: $DRAFT_FILE"
echo "Challenge: $CHALLENGE_FILE"
echo "Final: $SOLUTION_FILE"
