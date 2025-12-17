import { slugify, titleCaseFromKebab } from "./strings";

export const CATEGORY_DIR_TO_LABEL: Record<string, string> = {
  "01-foundational-infrastructure": "Foundational Infrastructure",
  "02-storage-data-platforms": "Storage & Data Platforms",
  "03-observability-reliability": "Observability & Reliability",
  "04-realtime-media": "Real-Time & Media",
  "05-social-discovery": "Social & Discovery",
  "06-commerce-fintech": "Commerce & Fintech",
  "07-ai-ml-infrastructure": "AI/ML Infrastructure",
  "08-security-access-control": "Security & Access Control",
  "09-iot-edge": "IoT & Edge",
  "10-strategic-problems": "Strategic Problems",
};

export function categoryLabelFromDir(categoryDir: string): string {
  if (CATEGORY_DIR_TO_LABEL[categoryDir]) return CATEGORY_DIR_TO_LABEL[categoryDir];

  const noPrefix = categoryDir.replace(/^\d{2}-/, "");
  return titleCaseFromKebab(noPrefix);
}

export function categorySlugFromLabel(label: string): string {
  return slugify(label);
}

