#!/usr/bin/env node
// fix-solution-wrappers.js - Strip various wrapper formats from solutions

const fs = require('fs');
const path = require('path');

const solutionsDir = path.join(__dirname, '..', 'solutions');

function fixContent(content, filePath) {
  let fixed = content;

  // Remove various prefixes like "Added `path`:", "Updated `path`:", etc.
  fixed = fixed.replace(/^(Added|Updated|Created|Wrote|Here is|Here's)\s+`[^`]+`[:\s]*\n+/i, '');
  fixed = fixed.replace(/^(Added|Updated|Created|Wrote|Here is|Here's)[^`\n]*:\s*\n+/i, '');

  // Remove lines that look like LLM commentary before the content
  while (fixed.match(/^[^\n#`-]*:\s*\n+```markdown/)) {
    fixed = fixed.replace(/^[^\n]*:\s*\n+/, '');
  }

  // Remove ```markdown wrapper (possibly multiple times)
  for (let i = 0; i < 3; i++) {
    if (fixed.startsWith('```markdown\n')) {
      fixed = fixed.slice('```markdown\n'.length);
    }
    if (fixed.endsWith('\n```')) {
      fixed = fixed.slice(0, -4);
    } else if (fixed.endsWith('\n```\n')) {
      fixed = fixed.slice(0, -5);
    } else if (fixed.endsWith('```')) {
      fixed = fixed.slice(0, -3);
    }
  }

  // Trim whitespace
  fixed = fixed.trim() + '\n';

  return fixed;
}

// Process all solutions
const categories = fs.readdirSync(solutionsDir).filter(f =>
  fs.statSync(path.join(solutionsDir, f)).isDirectory()
);

let fixed = 0;
for (const category of categories) {
  const categoryDir = path.join(solutionsDir, category);
  const files = fs.readdirSync(categoryDir).filter(f => f.endsWith('.md'));

  for (const file of files) {
    const filePath = path.join(categoryDir, file);
    const original = fs.readFileSync(filePath, 'utf8');
    const cleaned = fixContent(original, filePath);

    if (cleaned !== original) {
      fs.writeFileSync(filePath, cleaned);
      console.log(`Fixed: ${file}`);
      fixed++;
    }
  }
}

console.log(`\nFixed ${fixed} files`);
