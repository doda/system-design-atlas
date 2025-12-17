/** @type {import('tailwindcss').Config} */
import typography from "@tailwindcss/typography";

export default {
  darkMode: "class",
  content: ["./src/**/*.{astro,html,js,jsx,ts,tsx,md,mdx}"],
  theme: {
    extend: {
      fontFamily: {
        sans: [
          "ui-sans-serif",
          "system-ui",
          "-apple-system",
          "Segoe UI",
          "Roboto",
          "Helvetica",
          "Arial",
          "Apple Color Emoji",
          "Segoe UI Emoji",
        ],
        serif: [
          "Newsreader",
          "ui-serif",
          "Georgia",
          "Cambria",
          "Times New Roman",
          "Times",
          "serif",
        ],
        mono: [
          "ui-monospace",
          "SFMono-Regular",
          "Menlo",
          "Monaco",
          "Consolas",
          "Liberation Mono",
          "Courier New",
          "monospace",
        ],
      },
      colors: {
        sda: {
          bg: {
            DEFAULT: "rgb(var(--sda-bg) / <alpha-value>)",
            subtle: "rgb(var(--sda-bg-subtle) / <alpha-value>)",
          },
          fg: {
            DEFAULT: "rgb(var(--sda-fg) / <alpha-value>)",
            muted: "rgb(var(--sda-fg-muted) / <alpha-value>)",
          },
          border: "rgb(var(--sda-border) / <alpha-value>)",
          brand: "rgb(var(--sda-brand) / <alpha-value>)",
        },
      },
      boxShadow: {
        soft: "0 1px 2px rgb(0 0 0 / 0.05), 0 8px 24px rgb(0 0 0 / 0.08)",
      },
    },
  },
  plugins: [typography],
};
