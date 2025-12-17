#!/usr/bin/env node
/**
 * Validate Mermaid diagrams in markdown files
 * Run from frontend directory: node ../scripts/validate-mermaid.mjs
 * Or: cd frontend && node ../scripts/validate-mermaid.mjs [files...] [--fix]
 */

import { readFileSync, writeFileSync, readdirSync, statSync } from 'fs';
import { join, relative, dirname } from 'path';
import { fileURLToPath } from 'url';
import { createRequire } from 'module';

const __dirname = dirname(fileURLToPath(import.meta.url));
const require = createRequire(import.meta.url);

// We'll use mermaid's parse function via dynamic import
let mermaid;

function extractMermaidBlocks(content, filePath) {
  const blocks = [];
  const regex = /```mermaid\n([\s\S]*?)```/g;
  let match;
  let lineNum = 1;
  let lastIndex = 0;

  while ((match = regex.exec(content)) !== null) {
    // Count lines up to this match
    lineNum += content.slice(lastIndex, match.index).split('\n').length - 1;
    lastIndex = match.index;

    blocks.push({
      code: match[1].trim(),
      line: lineNum,
      file: filePath,
      fullMatch: match[0],
      index: match.index
    });
  }
  return blocks;
}

async function validateBlock(block) {
  try {
    await mermaid.parse(block.code);
    return { valid: true, block };
  } catch (error) {
    return {
      valid: false,
      block,
      error: error.message || String(error)
    };
  }
}

function findMarkdownFiles(dir) {
  const files = [];
  try {
    for (const entry of readdirSync(dir)) {
      const path = join(dir, entry);
      const stat = statSync(path);
      if (stat.isDirectory()) {
        files.push(...findMarkdownFiles(path));
      } else if (entry.endsWith('.md')) {
        files.push(path);
      }
    }
  } catch (e) {
    // Directory doesn't exist
  }
  return files;
}

// Common fixes for mermaid syntax issues
function attemptFix(code) {
  let fixed = code;

  // Fix 1: Quote labels with special characters that aren't quoted
  // Match node definitions like: A[Label with (parens)]  -> A["Label with (parens)"]
  fixed = fixed.replace(/(\w+)\[([^\]"]+[()&<>][^\]"]*)\]/g, '$1["$2"]');

  // Fix 2: Replace <br/> with <br> (some mermaid versions prefer this)
  fixed = fixed.replace(/<br\/>/g, '<br>');

  // Fix 3: Remove trailing whitespace on lines
  fixed = fixed.split('\n').map(line => line.trimEnd()).join('\n');

  // Fix 4: Ensure flowchart/graph declarations are valid
  fixed = fixed.replace(/^graph\s+(?!TB|BT|LR|RL|TD)/gm, 'graph TB\n');

  return fixed;
}

async function main() {
  // Dynamic import for ESM compatibility
  const { default: mermaidModule } = await import('mermaid');
  mermaid = mermaidModule;

  // Initialize mermaid for parsing
  mermaid.initialize({
    startOnLoad: false,
    securityLevel: 'strict',
    suppressErrors: true
  });

  const args = process.argv.slice(2);
  const autoFix = args.includes('--fix');
  const fileArgs = args.filter(a => !a.startsWith('--'));

  const projectRoot = process.cwd().replace(/\/frontend$/, '');
  const solutionsDir = join(projectRoot, 'solutions');

  const files = fileArgs.length > 0
    ? fileArgs
    : findMarkdownFiles(solutionsDir);

  if (files.length === 0) {
    console.log('No markdown files found');
    process.exit(0);
  }

  let totalBlocks = 0;
  let validBlocks = 0;
  let fixedBlocks = 0;
  const errors = [];

  for (const file of files) {
    let content = readFileSync(file, 'utf-8');
    const blocks = extractMermaidBlocks(content, file);
    let fileModified = false;

    for (const block of blocks) {
      totalBlocks++;
      let result = await validateBlock(block);

      if (!result.valid && autoFix) {
        // Try to fix
        const fixedCode = attemptFix(block.code);
        if (fixedCode !== block.code) {
          const fixedBlock = { ...block, code: fixedCode };
          const fixResult = await validateBlock(fixedBlock);
          if (fixResult.valid) {
            // Apply fix to content
            const newMatch = '```mermaid\n' + fixedCode + '\n```';
            content = content.slice(0, block.index) + newMatch + content.slice(block.index + block.fullMatch.length);
            fileModified = true;
            fixedBlocks++;
            result = fixResult;
          }
        }
      }

      if (result.valid) {
        validBlocks++;
      } else {
        errors.push(result);
      }
    }

    if (fileModified) {
      writeFileSync(file, content);
      console.log(`Fixed: ${relative(projectRoot, file)}`);
    }
  }

  console.log(`\n=== Mermaid Validation ===`);
  console.log(`Files scanned: ${files.length}`);
  console.log(`Diagrams found: ${totalBlocks}`);
  console.log(`Valid: ${validBlocks}`);
  if (autoFix) console.log(`Auto-fixed: ${fixedBlocks}`);
  console.log(`Invalid: ${errors.length}`);

  if (errors.length > 0) {
    console.log(`\n=== Errors ===\n`);
    for (const { block, error } of errors) {
      const relPath = relative(projectRoot, block.file);
      console.log(`${relPath}:${block.line}`);
      console.log(`  Error: ${error.split('\n')[0]}`);
      console.log(`  Code preview: ${block.code.slice(0, 100).replace(/\n/g, '↵')}...`);
      console.log();
    }
    process.exit(1);
  }

  console.log(`\n✓ All diagrams valid`);
}

main().catch(err => {
  console.error('Validation failed:', err.message);
  process.exit(1);
});
