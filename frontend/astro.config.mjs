import { defineConfig } from "astro/config";
import tailwind from "@astrojs/tailwind";
import { remarkMermaidBlocks } from "./src/lib/remark/mermaid.mjs";
import { rehypeMermaidBlocks } from "./src/lib/rehype/mermaid.mjs";
import rehypeSlug from "rehype-slug";

export default defineConfig({
  output: "static",
  integrations: [tailwind()],
  markdown: {
    syntaxHighlight: {
      excludeLangs: ["mermaid"],
    },
    shikiConfig: {
      themes: {
        light: "github-light",
        dark: "github-dark",
      },
    },
    remarkPlugins: [remarkMermaidBlocks],
    rehypePlugins: [rehypeSlug, rehypeMermaidBlocks],
  },
  vite: {
    server: {
      fs: {
        allow: [".."],
      },
    },
  },
});
