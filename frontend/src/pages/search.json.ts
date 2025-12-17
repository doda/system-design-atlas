import type { APIRoute } from "astro";
import { readFile } from "node:fs/promises";
import { getAllSolutions, solutionUrl } from "../lib/solutions";

function stripMarkdown(md: string): string {
  return md
    .replace(/```[\s\S]*?```/g, " ")
    .replace(/`[^`]*`/g, " ")
    .replace(/!\[[^\]]*]\([^)]+\)/g, " ")
    .replace(/\[[^\]]*]\([^)]+\)/g, " ")
    .replace(/^---[\s\S]*?---/m, " ")
    .replace(/[#>*_~-]/g, " ")
    .replace(/\s+/g, " ")
    .trim();
}

export const GET: APIRoute = async () => {
  const solutions = getAllSolutions();
  const items = await Promise.all(
    solutions.map(async (s) => {
      const file = s.module.file;
      let body = "";
      if (file) {
        try {
          body = await readFile(file, "utf-8");
        } catch {
          body = "";
        }
      }
      const text = stripMarkdown(body);
      return {
        title: s.title,
        url: solutionUrl(s),
        category: s.categoryLabel,
        categorySlug: s.categorySlug,
        difficulty: String(s.difficulty),
        tags: s.tags,
        text: text.slice(0, 20000),
      };
    }),
  );

  return new Response(JSON.stringify({ items }), {
    headers: {
      "content-type": "application/json; charset=utf-8",
      "cache-control": "public, max-age=3600",
    },
  });
};
