import { visit } from "unist-util-visit";

/**
 * Remark plugin to mark Mermaid code blocks so they can be processed by rehype.
 * This runs before Shiki, so Shiki won't try to syntax highlight Mermaid.
 */
export function remarkMermaidBlocks() {
  return (tree) => {
    visit(tree, "code", (node) => {
      if (node.lang === "mermaid") {
        // Mark as Mermaid so rehype plugin can find it
        node.data = node.data || {};
        node.data.mermaid = true;
      }
    });
  };
}

