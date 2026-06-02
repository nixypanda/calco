import type { SearchResult } from "@/api/foods";
import { UnstyledButton, Group, Stack, Text, Badge } from "@mantine/core";

interface FoodSearchResultRowProps {
  item: SearchResult;
  onSelect: () => void;
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
  showBarcode = false,
}: FoodSearchResultRowProps) {
  const meta = buildMeta(item, showBarcode);
  const tags = categoryTags(item.categories);
  const showCustom = item.source === "USER" && tags.length < 4;

  return (
    <UnstyledButton
      onClick={onSelect}
      p="xs"
      style={{
        width: "100%",
        textAlign: "left",
        borderBottom: "1px solid var(--mantine-color-default-border)",
      }}
    >
      <Group justify="space-between" align="flex-start" gap="sm" wrap="nowrap">
        <Stack gap={2} miw={0} style={{ flex: 1 }}>
          <Text size="sm" fw={500} lineClamp={2}>
            {item.name}
          </Text>
          {meta && (
            <Text size="xs" c="dimmed" truncate>
              {meta}
            </Text>
          )}
        </Stack>
        {(tags.length > 0 || showCustom) && (
          <Group gap={4} justify="flex-end" maw={120} style={{ flexWrap: "wrap" }}>
            {tags.map((tag) => (
              <Badge
                key={tag}
                size="xs"
                variant="light"
                color={tag.startsWith("+") ? "gray" : "blue"}
                title={tag.startsWith("+") ? undefined : tag}
              >
                {tag}
              </Badge>
            ))}
            {showCustom && (
              <Badge size="xs" variant="outline" color="gray">
                Custom
              </Badge>
            )}
          </Group>
        )}
      </Group>
    </UnstyledButton>
  );
}
