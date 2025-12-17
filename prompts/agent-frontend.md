# System Design Atlas - Frontend Agent Prompt

You are building a beautiful, statically-generated frontend for "System Design Atlas" - a collection of 100 system design solutions for engineers preparing for interviews and architectural reviews.

## Project Context

The content lives in `/solutions/{category-dir}/{slug}.md` as Markdown files with YAML frontmatter:

```yaml
---
title: "Distributed Lock Service"
category: "Foundational Infrastructure"
difficulty: "Hard"
tags: ["distributed-systems", "consensus", "coordination"]
---
```

Each solution contains:
- Markdown prose with headers, lists, code blocks
- Mermaid diagrams (```mermaid blocks)
- A "Simplification Notes" section at the end

## Requirements

### Core Features
1. **Home page**: Grid/list of all 100 problems, filterable by category and difficulty
2. **Problem page**: Render each solution beautifully with:
   - Rendered Mermaid diagrams (client-side or build-time)
   - Syntax-highlighted code blocks
   - Clean typography for long-form technical reading
   - Table of contents (generated from headers)
   - Difficulty badge, category label, tags
3. **Search**: Full-text search across all solutions (client-side is fine)
4. **Category pages**: Browse by category (10 categories, ~10 problems each)
5. **Navigation**: Previous/next problem within category

### Design Requirements
- **Clean, minimal, focused on readability** - this is technical reference content
- **Dark mode support** - engineers live in dark mode
- **Mobile responsive** - readable on phones/tablets
- **Fast** - static site, no loading spinners
- **Accessible** - semantic HTML, keyboard navigation, good contrast

### Visual Style
- Inspired by: Stripe Docs, Tailwind Docs, Linear's aesthetic
- Monospace fonts for code, clean sans-serif for prose
- Subtle use of color for categories/difficulty badges
- Generous whitespace, not cramped
- Mermaid diagrams should match the site's color scheme (especially dark mode)

## Tech Stack (Recommended)

Use **Astro** with the following:
- `@astrojs/mdx` or standard markdown with remark/rehype plugins
- `astro-mermaid` or client-side Mermaid.js for diagrams
- Tailwind CSS for styling
- `pagefind` or `fuse.js` for client-side search
- Static output (`output: 'static'`) - no server required

Alternative stacks (if you prefer):
- Next.js with static export + next-mdx-remote
- Eleventy (11ty) with markdown-it
- VitePress (if you want Vue)

## File Structure

```
frontend/
├── src/
│   ├── layouts/
│   │   ├── BaseLayout.astro
│   │   └── SolutionLayout.astro
│   ├── pages/
│   │   ├── index.astro              # Home with grid
│   │   ├── search.astro             # Search page
│   │   ├── category/
│   │   │   └── [category].astro     # Category listing
│   │   └── solutions/
│   │       └── [...slug].astro      # Dynamic solution pages
│   ├── components/
│   │   ├── Header.astro
│   │   ├── Footer.astro
│   │   ├── SolutionCard.astro
│   │   ├── TableOfContents.astro
│   │   ├── DifficultyBadge.astro
│   │   ├── CategoryLabel.astro
│   │   ├── TagList.astro
│   │   ├── Search.astro
│   │   └── MermaidDiagram.astro
│   └── styles/
│       └── global.css
├── public/
│   └── favicon.svg
├── astro.config.mjs
├── tailwind.config.js
└── package.json
```

## Content Loading

Solutions are in `../solutions/{category-dir}/{slug}.md`. Use Astro's content collections or glob imports:

```javascript
// Load all solutions
const solutions = await Astro.glob('../solutions/**/*.md');

// Parse frontmatter for filtering/sorting
const problems = solutions.map(s => ({
  slug: s.file.split('/').pop().replace('.md', ''),
  category: s.frontmatter.category,
  title: s.frontmatter.title,
  difficulty: s.frontmatter.difficulty,
  tags: s.frontmatter.tags,
  Content: s.Content
}));
```

## Categories (10 total)

```
01-foundational-infrastructure/  → "Foundational Infrastructure"
02-data-systems/                 → "Data Systems"
03-messaging-streaming/          → "Messaging & Streaming"
04-storage-cdn/                  → "Storage & CDN"
05-social-collaborative/         → "Social & Collaborative"
06-commerce-fintech/             → "Commerce & Fintech"
07-media-entertainment/          → "Media & Entertainment"
08-iot-realtime/                 → "IoT & Real-time"
09-developer-infra/              → "Developer Infrastructure"
10-ai-ml-systems/                → "AI/ML Systems"
```

## Key Implementation Details

### Mermaid Rendering
```astro
<!-- Option 1: Client-side -->
<script src="https://cdn.jsdelivr.net/npm/mermaid/dist/mermaid.min.js"></script>
<script>
  mermaid.initialize({
    startOnLoad: true,
    theme: document.documentElement.classList.contains('dark') ? 'dark' : 'default'
  });
</script>

<!-- Option 2: Build-time with rehype-mermaid -->
```

### Table of Contents
Extract headings from the markdown AST and render a sticky sidebar TOC on desktop.

### Search
Use Pagefind (recommended for Astro) - it indexes at build time and provides fast client-side search:
```bash
npx pagefind --source dist
```

### Dark Mode
Use Tailwind's `dark:` variants with a toggle that respects system preference:
```javascript
// Check system preference, allow manual override
const theme = localStorage.theme || (window.matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light');
document.documentElement.classList.toggle('dark', theme === 'dark');
```

## Deliverables

1. Complete Astro project in `/frontend` directory
2. All components, layouts, and pages
3. Tailwind styling with dark mode
4. Mermaid diagram rendering
5. Search functionality
6. Build script in package.json: `npm run build` outputs to `dist/`
7. README with setup instructions

## Quality Bar

- Lighthouse score: 95+ on all metrics
- No layout shift when Mermaid diagrams render
- Search returns results in <100ms
- Works without JavaScript for core reading (progressive enhancement)
- Looks polished enough to show in a portfolio

Build the frontend now.
