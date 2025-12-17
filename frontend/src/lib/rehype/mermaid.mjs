import { visit } from "unist-util-visit";

function extractText(node) {
  if (!node) return "";
  if (node.type === "text" && typeof node.value === "string") return node.value;
  if (Array.isArray(node.children)) return node.children.map(extractText).join("");
  return "";
}

function clamp(n, min, max) {
  return Math.max(min, Math.min(max, n));
}

/**
 * Rehype plugin to process Mermaid code blocks and convert them to divs for client-side rendering.
 * This runs after Shiki, so we need to detect Mermaid blocks in the pre/code structure.
 */
export function rehypeMermaidBlocks() {
  return (tree) => {
    visit(tree, "element", (node, index, parent) => {
      if (!parent || typeof index !== "number") return;
      if (node.tagName !== "pre") return;

      // Check data-language attribute on pre element (Shiki adds this)
      const preDataLang = node.properties?.["data-language"];
      if (preDataLang === "mermaid") {
        // Find the code element inside pre
        const code = Array.isArray(node.children)
          ? node.children.find((c) => c?.type === "element" && c?.tagName === "code")
          : null;

        if (!code) return;

        // Extract the diagram source code from all nested spans
        const diagramSource = extractText(code);
        if (!diagramSource.trim()) return;

        // Calculate minimum height based on line count
        const lines = diagramSource.split("\n").filter((l) => l.trim().length > 0).length;
        const minHeight = clamp(120 + lines * 14, 180, 900);

        // Replace pre/code with div for Mermaid rendering
        parent.children[index] = {
          type: "element",
          tagName: "div",
          properties: {
            className: ["sda-mermaid", "mermaid"],
            style: `min-height:${minHeight}px`,
            "data-mermaid": "true",
          },
          children: [{ type: "text", value: diagramSource }],
        };
        return;
      }

      // Fallback: check code element for language-mermaid class
      const code = Array.isArray(node.children)
        ? node.children.find((c) => c?.type === "element" && c?.tagName === "code")
        : null;

      if (!code) return;

      const codeClass = code?.properties?.className;
      const codeClasses = Array.isArray(codeClass) ? codeClass : typeof codeClass === "string" ? [codeClass] : [];
      
      const isMermaid = codeClasses.some((cls) => typeof cls === "string" && cls.toLowerCase().includes("mermaid"));

      if (!isMermaid) return;

      // Extract the diagram source code
      const diagramSource = extractText(code);
      if (!diagramSource.trim()) return;

      // Calculate minimum height based on line count
      const lines = diagramSource.split("\n").filter((l) => l.trim().length > 0).length;
      const minHeight = clamp(120 + lines * 14, 180, 900);

      // Replace pre/code with div for Mermaid rendering
      parent.children[index] = {
        type: "element",
        tagName: "div",
        properties: {
          className: ["sda-mermaid", "mermaid"],
          style: `min-height:${minHeight}px`,
          "data-mermaid": "true",
        },
        children: [{ type: "text", value: diagramSource }],
      };
    });
  };
}

