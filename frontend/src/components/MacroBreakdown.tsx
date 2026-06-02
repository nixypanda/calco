import { Group, Paper, SimpleGrid, Stack, Text } from "@mantine/core";
import { MacroRing } from "@/components/MacroRing";

const MACRO_COLORS = {
  protein: "var(--mantine-color-blue-6)",
  carbs: "var(--mantine-color-orange-6)",
  fat: "var(--mantine-color-yellow-6)",
} as const;

interface NutrientEntry {
  code: string;
  amount: number | string;
}

function parseAmount(val: number | string): number {
  if (typeof val === "number")
    return Number.isFinite(val) && val >= 0 ? val : 0;
  const n = parseFloat(val);
  return Number.isFinite(n) && n >= 0 ? n : 0;
}

function getNutrientAmount(nutrients: NutrientEntry[], code: string): number {
  const entry = nutrients.find((n) => n.code === code);
  return entry ? parseAmount(entry.amount) : 0;
}

function MacroStat({
  name,
  grams,
  percent,
  color,
}: {
  name: string;
  grams: number;
  percent: number;
  color: string;
}) {
  return (
    <Stack
      gap={0}
      align="center"
      px="xs"
      style={{ borderLeft: `3px solid ${color}` }}
    >
      <Text size="xs" fw={600} style={{ color }}>
        {Math.round(percent)}%
      </Text>
      <Text fw={600}>{grams.toFixed(1)}g</Text>
      <Text size="xs" fw={500} c="dimmed">
        {name}
      </Text>
    </Stack>
  );
}

export function MacroBreakdown({ nutrients }: { nutrients: NutrientEntry[] }) {
  const protein = getNutrientAmount(nutrients, "PROTEIN_G");
  const carbs = getNutrientAmount(nutrients, "CARBS_G");
  const fat = getNutrientAmount(nutrients, "FAT_G");
  const calories = getNutrientAmount(nutrients, "ENERGY_KCAL");
  const totalKcal = protein * 4 + carbs * 4 + fat * 9;
  const pct = (kcal: number) => (totalKcal > 0 ? (kcal / totalKcal) * 100 : 0);
  const proteinPct = pct(protein * 4);
  const carbsPct = pct(carbs * 4);
  const fatPct = pct(fat * 9);

  return (
    <Paper p="md">
      <Group gap="xl" align="center">
        <MacroRing
          segments={[
            { value: proteinPct, color: MACRO_COLORS.protein },
            { value: carbsPct, color: MACRO_COLORS.carbs },
            { value: fatPct, color: MACRO_COLORS.fat },
          ]}
          total={100}
        >
          <Text fw={800}>{Math.round(calories)}</Text>
          <Text size="xs" fw={600} c="dimmed">
            kcal
          </Text>
        </MacroRing>
        <SimpleGrid cols={3} style={{ flex: 1 }}>
          <MacroStat
            name="Protein"
            grams={protein}
            percent={proteinPct}
            color={MACRO_COLORS.protein}
          />
          <MacroStat
            name="Carbs"
            grams={carbs}
            percent={carbsPct}
            color={MACRO_COLORS.carbs}
          />
          <MacroStat
            name="Fat"
            grams={fat}
            percent={fatPct}
            color={MACRO_COLORS.fat}
          />
        </SimpleGrid>
      </Group>
    </Paper>
  );
}
