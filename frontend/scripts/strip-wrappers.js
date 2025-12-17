#!/usr/bin/env node
/**
 * Strip ```markdown wrappers that LLMs sometimes add to output.
 * Run before build: node scripts/strip-wrappers.js
 */

import { readdir, readFile, writeFile } from 'fs/promises';
import { join, resolve } from 'path';

const DIRS = [
  resolve(import.meta.dirname, '../../solutions'),
  resolve(import.meta.dirname, '../../drafts'),
  resolve(import.meta.dirname, '../../reviewed'),
];

async function* walkMd(dir) {
  try {
    const entries = await readdir(dir, { withFileTypes: true });
    for (const entry of entries) {
      const path = join(dir, entry.name);
      if (entry.isDirectory()) {
        yield* walkMd(path);
      } else if (entry.name.endsWith('.md')) {
        yield path;
      }
    }
  } catch {
    // Directory doesn't exist, skip
  }
}

async function stripWrapper(filePath) {
  let content = await readFile(filePath, 'utf8');
  let modified = false;

  // Strip ```markdown from start
  if (content.startsWith('```markdown\n')) {
    content = content.slice('```markdown\n'.length);
    modified = true;
  } else if (content.startsWith('```markdown\r\n')) {
    content = content.slice('```markdown\r\n'.length);
    modified = true;
  }

  // Strip ``` from end
  if (content.endsWith('\n```\n')) {
    content = content.slice(0, -4);
    modified = true;
  } else if (content.endsWith('\n```')) {
    content = content.slice(0, -4);
    modified = true;
  } else if (content.endsWith('```\n')) {
    content = content.slice(0, -4);
    modified = true;
  } else if (content.endsWith('```')) {
    content = content.slice(0, -3);
    modified = true;
  }

  if (modified) {
    await writeFile(filePath, content);
    return true;
  }
  return false;
}

async function main() {
  let fixed = 0;
  let total = 0;

  for (const dir of DIRS) {
    for await (const file of walkMd(dir)) {
      total++;
      if (await stripWrapper(file)) {
        console.log(`Fixed: ${file}`);
        fixed++;
      }
    }
  }

  console.log(`\nChecked ${total} files, fixed ${fixed} wrappers.`);
}

main().catch(console.error);
