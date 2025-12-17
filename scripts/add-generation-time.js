#!/usr/bin/env node
// add-generation-time.js - Add generation_time_seconds to solution frontmatter

const fs = require('fs');
const path = require('path');

const projectDir = path.join(__dirname, '..');
const timesFile = path.join(projectDir, 'generation-times.json');
const solutionsDir = path.join(projectDir, 'solutions');

const times = JSON.parse(fs.readFileSync(timesFile, 'utf8'));

function addTimeToFrontmatter(filePath, timeSeconds) {
  let content = fs.readFileSync(filePath, 'utf8');

  // Handle markdown wrapper
  if (content.startsWith('```markdown\n')) {
    content = content.slice('```markdown\n'.length);
    if (content.endsWith('\n```') || content.endsWith('\n```\n')) {
      content = content.replace(/\n```\n?$/, '');
    }
  }

  // Find the frontmatter
  const frontmatterMatch = content.match(/^---\n([\s\S]*?)\n---/);
  if (!frontmatterMatch) {
    console.log(`  No frontmatter found in ${filePath}`);
    return;
  }

  // Check if already has generation_time_seconds
  if (content.includes('generation_time_seconds:')) {
    console.log(`  Already has time: ${path.basename(filePath)}`);
    return;
  }

  // Add generation_time_seconds after the opening ---
  const newContent = content.replace(
    /^---\n/,
    `---\ngeneration_time_seconds: ${timeSeconds}\n`
  );

  fs.writeFileSync(filePath, newContent);
  console.log(`  Added ${timeSeconds}s to ${path.basename(filePath)}`);
}

// Process all solutions
const categories = fs.readdirSync(solutionsDir).filter(f =>
  fs.statSync(path.join(solutionsDir, f)).isDirectory()
);

let processed = 0;
for (const category of categories) {
  const categoryDir = path.join(solutionsDir, category);
  const files = fs.readdirSync(categoryDir).filter(f => f.endsWith('.md'));

  for (const file of files) {
    const slug = file.replace('.md', '');
    const time = times[slug];

    if (time) {
      addTimeToFrontmatter(path.join(categoryDir, file), time);
      processed++;
    } else {
      console.log(`  No time for: ${slug}`);
    }
  }
}

console.log(`\nProcessed ${processed} solutions`);
