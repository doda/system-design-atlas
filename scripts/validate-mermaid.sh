#!/bin/bash
# Validate Mermaid diagrams in markdown files
# Usage: ./scripts/validate-mermaid.sh [--fix]
# Run from project root or frontend directory

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
FRONTEND_DIR="$PROJECT_DIR/frontend"

# Find mmdc
MMDC="$FRONTEND_DIR/node_modules/.bin/mmdc"
if [[ ! -x "$MMDC" ]]; then
    echo "Error: mermaid-cli not found. Run: cd frontend && npm install"
    exit 1
fi

SOLUTIONS_DIR="$PROJECT_DIR/solutions"
TEMP_DIR=$(mktemp -d)
trap "rm -rf $TEMP_DIR" EXIT

FIX_MODE=false
if [[ "$1" == "--fix" ]]; then
    FIX_MODE=true
fi

total=0
valid=0
invalid=0
fixed=0

# Extract and validate mermaid blocks
for md_file in $(find "$SOLUTIONS_DIR" -name "*.md" 2>/dev/null); do
    rel_path="${md_file#$PROJECT_DIR/}"

    # Extract mermaid blocks with line numbers
    block_num=0
    in_mermaid=false
    line_num=0
    block_start=0
    block_content=""

    while IFS= read -r line || [[ -n "$line" ]]; do
        ((line_num++))

        if [[ "$line" == '```mermaid' ]]; then
            in_mermaid=true
            block_start=$line_num
            block_content=""
            continue
        fi

        if [[ "$in_mermaid" == true && "$line" == '```' ]]; then
            in_mermaid=false
            ((block_num++))
            ((total++))

            # Write block to temp file
            temp_file="$TEMP_DIR/block_${block_num}.mmd"
            echo "$block_content" > "$temp_file"

            # Validate with mmdc
            if $MMDC -i "$temp_file" -o "$TEMP_DIR/out.svg" 2>/dev/null; then
                ((valid++))
            else
                ((invalid++))
                echo ""
                echo "ERROR: $rel_path:$block_start"
                echo "  Preview: $(echo "$block_content" | head -3 | tr '\n' ' ' | cut -c1-80)..."

                # Try to get error message
                $MMDC -i "$temp_file" -o "$TEMP_DIR/out.svg" 2>&1 | head -5 | sed 's/^/  /'
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
    done < "$md_file"
done

echo ""
echo "=== Mermaid Validation ==="
echo "Diagrams found: $total"
echo "Valid: $valid"
echo "Invalid: $invalid"

if [[ $invalid -gt 0 ]]; then
    echo ""
    echo "Run with --fix to attempt auto-repair (coming soon)"
    exit 1
else
    echo ""
    echo "✓ All diagrams valid"
fi
