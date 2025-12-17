import { categoryLabelFromDir, categorySlugFromLabel } from "./categories";

export type Difficulty = "Easy" | "Medium" | "Hard" | string;

export type SolutionModule = {
  frontmatter: {
    title?: string;
    category?: string;
    difficulty?: Difficulty;
    tags?: string[];
    description?: string;
    generation_time_seconds?: number;
  };
  file?: string;
  Content: any;
  getHeadings?: () => Promise<Array<{ depth: number; slug: string; text: string }>> | Array<{ depth: number; slug: string; text: string }>;
};

export type Solution = {
  title: string;
  slug: string;
  categoryLabel: string;
  categorySlug: string;
  categoryDir: string;
  difficulty: Difficulty;
  tags: string[];
  generationTimeSeconds?: number;
  importPath: string;
  module: SolutionModule;
};

const solutionModules = import.meta.glob<SolutionModule>("../../../solutions/**/*.md", { eager: true });
const draftModules = import.meta.glob<SolutionModule>("../../../drafts/*.md", { eager: true });
const reviewedModules = import.meta.glob<SolutionModule>("../../../reviewed/*.md", { eager: true });
let cachedAllSolutions: Solution[] | null = null;

function parseCategoryDir(importPath: string): string {
  const parts = importPath.split("/");
  const solutionsIndex = parts.lastIndexOf("solutions");
  if (solutionsIndex === -1) return "solutions";
  return parts[solutionsIndex + 1] ?? "solutions";
}

function parseFileSlug(importPath: string): string {
  const file = importPath.split("/").at(-1) ?? importPath;
  return file.replace(/\.md$/i, "");
}

export function getAllSolutions(): Solution[] {
  if (cachedAllSolutions) return cachedAllSolutions;
  const solutions = Object.entries(solutionModules).map(([importPath, module]) => {
    const categoryDir = parseCategoryDir(importPath);
    const slug = parseFileSlug(importPath);
    const categoryLabel = module.frontmatter?.category ?? categoryLabelFromDir(categoryDir);
    const categorySlug = categorySlugFromLabel(categoryLabel);

    return {
      title: module.frontmatter?.title ?? slug,
      slug,
      categoryLabel,
      categorySlug,
      categoryDir,
      difficulty: module.frontmatter?.difficulty ?? "Unknown",
      tags: module.frontmatter?.tags ?? [],
      generationTimeSeconds: module.frontmatter?.generation_time_seconds,
      importPath,
      module,
    };
  });

  solutions.sort((a, b) => a.title.localeCompare(b.title));
  cachedAllSolutions = solutions;
  return cachedAllSolutions;
}

export function getCategories() {
  const map = new Map<string, { label: string; slug: string; dir: string; count: number }>();
  for (const solution of getAllSolutions()) {
    const existing = map.get(solution.categorySlug);
    if (existing) {
      existing.count += 1;
      continue;
    }
    map.set(solution.categorySlug, {
      label: solution.categoryLabel,
      slug: solution.categorySlug,
      dir: solution.categoryDir,
      count: 1
    });
  }
  // Sort by directory name (01-xxx, 02-xxx, etc.) to maintain defined order
  return Array.from(map.values()).sort((a, b) => a.dir.localeCompare(b.dir));
}

export function getSolutionsByCategory(categorySlug: string): Solution[] {
  return getAllSolutions().filter((s) => s.categorySlug === categorySlug);
}

export function getSolutionByParams(categorySlug: string, slug: string): Solution | undefined {
  return getAllSolutions().find((s) => s.categorySlug === categorySlug && s.slug === slug);
}

export function getPrevNextWithinCategory(solution: Solution): { prev?: Solution; next?: Solution } {
  const list = getSolutionsByCategory(solution.categorySlug);
  const idx = list.findIndex((s) => s.slug === solution.slug);
  return {
    prev: idx > 0 ? list[idx - 1] : undefined,
    next: idx >= 0 && idx < list.length - 1 ? list[idx + 1] : undefined,
  };
}

export function solutionUrl(solution: Pick<Solution, "categorySlug" | "slug">): string {
  return `/solutions/${solution.categorySlug}/${solution.slug}`;
}

export function categoryUrl(categorySlug: string): string {
  return `/category/${categorySlug}`;
}

export type PipelineStage = "draft" | "reviewed" | "final";

export function getDraftModule(slug: string): SolutionModule | undefined {
  const draftPath = `../../../drafts/${slug}.md`;
  return draftModules[draftPath];
}

export function getReviewedModule(slug: string): SolutionModule | undefined {
  const reviewedPath = `../../../reviewed/${slug}.md`;
  return reviewedModules[reviewedPath];
}

export function getSolutionModule(slug: string, categoryDir: string): SolutionModule | undefined {
  const solutionPath = `../../../solutions/${categoryDir}/${slug}.md`;
  return solutionModules[solutionPath];
}

export function getSolutionStage(
  slug: string,
  categoryDir: string,
  stage: PipelineStage
): SolutionModule | undefined {
  switch (stage) {
    case "draft":
      return getDraftModule(slug);
    case "reviewed":
      return getReviewedModule(slug);
    case "final":
      return getSolutionModule(slug, categoryDir);
    default:
      return getSolutionModule(slug, categoryDir);
  }
}

export function hasStage(slug: string, categoryDir: string, stage: PipelineStage): boolean {
  return getSolutionStage(slug, categoryDir, stage) !== undefined;
}
