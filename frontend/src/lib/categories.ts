export function parseCategoriesInput(value: string): string[] {
  const categories: string[] = [];

  for (const raw of value.split(",")) {
    const normalized = raw.trim().toLowerCase();
    if (normalized && !categories.includes(normalized)) {
      categories.push(normalized);
    }
  }

  return categories;
}

export function formatCategoriesInput(categories: string[]): string {
  return categories.join(", ");
}
