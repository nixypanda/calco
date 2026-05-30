import { Card } from "@/components/ui/card";
import { MacroRing } from "@/components/MacroRing";

const MACRO_COLORS = {
  protein: "hsl(var(--chart-2))",
  carbs: "hsl(var(--chart-3))",
  fat: "hsl(var(--chart-4))",
} as const;

interface NutrientEntry {
  code: string;
  amount: number | string;
}

function parseAmount(val: number | string): number {
  if (typeof val === "number") return isFinite(val) && val >= 0 ? val : 0;
  const n = parseFloat(val);
  return isFinite(n) && n >= 0 ? n : 0;
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
    <div className="flex flex-col border-l-[3px] px-2 text-center" style={{ borderColor: color }}>
      <span className="text-xs font-semibold" style={{ color }}>
        {Math.round(percent)}%
      </span>
      <span className="font-semibold">{grams.toFixed(1)}g</span>
      <span className="text-muted-foreground text-xs font-medium">{name}</span>
    </div>
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
    <Card className="flex items-center gap-8 p-4">
      <MacroRing
        segments={[
          { value: proteinPct, color: MACRO_COLORS.protein },
          { value: carbsPct, color: MACRO_COLORS.carbs },
          { value: fatPct, color: MACRO_COLORS.fat },
        ]}
        total={100}
      >
        <span className="text-base font-extrabold leading-none">{Math.round(calories)}</span>
        <span className="text-muted-foreground text-xs font-semibold">kcal</span>
      </MacroRing>
      <div className="grid grid-cols-3 flex-1">
        <MacroStat name="Protein" grams={protein} percent={proteinPct} color={MACRO_COLORS.protein} />
        <MacroStat name="Carbs" grams={carbs} percent={carbsPct} color={MACRO_COLORS.carbs} />
        <MacroStat name="Fat" grams={fat} percent={fatPct} color={MACRO_COLORS.fat} />
      </div>
    </Card>
  );
}
