import type { SearchResult } from "@/api/foods";
import { cn } from "@/lib/utils";

interface FoodSearchResultRowProps {
  item: SearchResult;
  onSelect: () => void;
  className?: string;
  showBarcode?: boolean;
}

function formatNumber(value: string | null): string | null {
  if (!value) return null;
  const parsed = Number(value);
  if (!Number.isFinite(parsed)) return value;
  return parsed.toLocaleString(undefined, {
    maximumFractionDigits: parsed < 10 ? 1 : 0,
  });
}

function buildMeta(item: SearchResult, showBarcode: boolean): string {
  const parts: string[] = [];
  const servingSize = formatNumber(item.serving_size_g);
  const servingCalories = formatNumber(item.energy_kcal_per_serving);
  const per100gCalories = formatNumber(item.energy_kcal_per_100g);

  if (item.brand) parts.push(item.brand);
  if (showBarcode && item.barcode) parts.push(item.barcode);

  if (servingCalories) {
    parts.push(`${servingCalories} kcal`);
    parts.push("1 serving");
  } else if (per100gCalories) {
    parts.push(`${per100gCalories} kcal`);
    parts.push("per 100 g");
  } else if (servingSize) {
    parts.push("1 serving");
    parts.push(`${servingSize} g`);
  }

  return parts.join(" · ");
}

function categoryTags(categories: string[]): string[] {
  if (categories.length <= 4) return categories;
  return [...categories.slice(0, 3), `+${categories.length - 3}`];
}

export function FoodSearchResultRow({
  item,
  onSelect,
  className,
  showBarcode = false,
}: FoodSearchResultRowProps) {
  const meta = buildMeta(item, showBarcode);
  const tags = categoryTags(item.categories);
  const showCustom = item.source === "USER" && tags.length < 4;
  const hasTagArea = tags.length > 0 || showCustom;

  return (
    <button
      type="button"
      className={cn(
        "grid w-full items-center gap-2 border-b border-border px-3 py-2 text-left transition-colors last:border-b-0 hover:bg-muted/55 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring/45",
        hasTagArea
          ? "grid-cols-[minmax(0,1fr)_7.25rem] min-[380px]:grid-cols-[minmax(0,1fr)_8rem]"
          : "grid-cols-1",
        className,
      )}
      onClick={onSelect}
    >
      <span className="min-w-0">
        <span className="line-clamp-2 text-sm font-medium leading-5">{item.name}</span>
        {meta && (
          <span className="mt-0.5 block truncate text-xs leading-4 text-muted-foreground">
            {meta}
          </span>
        )}
      </span>

      {hasTagArea && (
        <span className="ml-auto flex max-h-9 max-w-[7.25rem] flex-row-reverse flex-wrap items-start justify-start gap-1 overflow-hidden min-[380px]:max-w-32">
          {tags.map((tag) => (
            <span
              key={tag}
              className={cn(
                "shrink-0 whitespace-nowrap rounded-md border border-transparent bg-secondary px-1.5 text-center text-[10px] font-medium leading-4 text-secondary-foreground",
                tag.startsWith("+") && "bg-muted text-muted-foreground",
              )}
              title={tag.startsWith("+") ? undefined : tag}
            >
              {tag}
            </span>
          ))}
          {showCustom && (
            <span className="shrink-0 whitespace-nowrap rounded-md border border-border px-1.5 text-center text-[10px] font-medium leading-4 text-foreground">
              Custom
            </span>
          )}
        </span>
      )}
    </button>
  );
}
