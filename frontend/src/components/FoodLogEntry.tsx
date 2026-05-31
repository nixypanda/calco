import { useMemo, useState } from "react";
import { Link } from "react-router-dom";
import { Minus, Plus } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Card } from "@/components/ui/card";
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";
import { ErrorBanner } from "@/components/ErrorBanner";
import { PageHeader } from "@/components/PageHeader";
import { FieldRow } from "@/components/FieldRow";
import { MacroBreakdown } from "@/components/MacroBreakdown";
import { NutrientsTable } from "@/components/NutrientsTable";
import { scaleNutrients } from "@/lib/scaleNutrients";
import type { ProductDetail, UnitItem } from "@/api/foods";
import type { NutrientSnapshotDto } from "@/api/logs";

function NumberStepper({
  value,
  onChange,
  step = 1,
  min,
}: {
  value: string;
  onChange: (v: string) => void;
  step?: number;
  min?: number;
}) {
  const adjust = (delta: number) => {
    const n = parseFloat(value);
    const current = isFinite(n) ? n : 0;
    let next = current + delta;
    if (min != null && next < min) next = min;
    onChange(Number.isInteger(next) ? String(next) : next.toFixed(2).replace(/\.?0+$/, ""));
  };
  const btn =
    "h-8 w-8 inline-flex items-center justify-center rounded-full border border-white/60 bg-white/55 backdrop-blur-xl text-foreground shadow-[0_2px_8px_rgb(15_12_40_/_0.06)] hover:bg-white/80 dark:border-white/10 dark:bg-white/[0.06] dark:hover:bg-white/[0.14] disabled:opacity-40";
  return (
    <div className="flex items-center justify-end gap-2">
      <button
        type="button"
        onClick={() => adjust(-step)}
        className={btn}
        aria-label="Decrement"
      >
        <Minus className="h-3.5 w-3.5" />
      </button>
      <input
        type="text"
        inputMode="decimal"
        value={value}
        onChange={(e) => onChange(e.target.value)}
        className="w-16 text-center text-muted-foreground font-semibold bg-transparent border-0 outline-none focus:ring-2 focus:ring-ring/50 rounded-md"
      />
      <button
        type="button"
        onClick={() => adjust(step)}
        className={btn}
        aria-label="Increment"
      >
        <Plus className="h-3.5 w-3.5" />
      </button>
    </div>
  );
}

const MEAL_SLOTS = [
  { value: "breakfast", label: "Breakfast" },
  { value: "lunch", label: "Lunch" },
  { value: "dinner", label: "Dinner" },
  { value: "snack", label: "Snack" },
] as const;

export interface LogValues {
  amount: string;
  unit: string;
  slot: string;
  notes: string;
}

export interface NutrientSnapshot {
  amount: string;
  unit: string;
  nutrients: NutrientSnapshotDto[];
}

interface Props {
  title: string;
  itemName: string;
  food: ProductDetail | null;
  snapshot?: NutrientSnapshot;
  units: UnitItem[];
  initial: LogValues;
  loggedAt?: string;
  brand?: string | null;
  category?: string | null;
  servingSizeG?: string | null;
  customFoodEditPath?: string;
  submitLabel: string;
  submittingLabel: string;
  onSubmit: (values: LogValues) => Promise<void>;
  onDelete?: () => Promise<void>;
  onBack: () => void;
  backLabel: string;
}

function formatTimestamp(ts: string): string {
  const d = new Date(ts);
  return d.toLocaleString("en-US", {
    weekday: "short",
    month: "short",
    day: "numeric",
    hour: "2-digit",
    minute: "2-digit",
  });
}

export function FoodLogEntry({
  title,
  itemName,
  food,
  snapshot,
  units,
  initial,
  loggedAt,
  brand,
  category,
  servingSizeG,
  customFoodEditPath,
  submitLabel,
  submittingLabel,
  onSubmit,
  onDelete,
  onBack,
  backLabel,
}: Props) {
  const [values, setValues] = useState<LogValues>(initial);
  const [submitting, setSubmitting] = useState(false);
  const [deleting, setDeleting] = useState(false);
  const [error, setError] = useState("");

  const computedNutrients = useMemo(() => {
    const parsed = parseFloat(values.amount);
    const amount = isFinite(parsed) && parsed >= 0 ? parsed : 0;

    // Snapshot baseline: same unit as recorded → linear-scale the stored values.
    // Preserves historical accuracy even if the food's per-100g has drifted.
    if (snapshot && snapshot.unit === values.unit) {
      const base = parseFloat(snapshot.amount) || 0;
      if (base > 0) {
        const factor = amount / base;
        return snapshot.nutrients.map((n) => ({
          code: n.code,
          amount: (parseFloat(n.amount) || 0) * factor,
          unit: n.unit,
        }));
      }
    }

    // Unit changed (or no snapshot): fall through to live food scaling.
    if (food && food.nutrients && food.nutrients.length > 0) {
      return scaleNutrients(food.nutrients, amount, values.unit, food.servings ?? []);
    }

    // No food data either — show snapshot values unscaled.
    return (snapshot?.nutrients ?? []).map((n) => ({
      code: n.code,
      amount: parseFloat(n.amount) || 0,
      unit: n.unit,
    }));
  }, [food, snapshot, values.amount, values.unit]);

  const unitOptions = useMemo(() => {
    const present = units.some((u) => u.code === values.unit);
    if (present || !values.unit) return units;
    return [{ code: values.unit, name: values.unit, kind: "" }, ...units];
  }, [units, values.unit]);

  const handleSubmit = async () => {
    setSubmitting(true);
    setError("");
    try {
      await onSubmit(values);
    } catch (e: unknown) {
      setError(e instanceof Error ? e.message : "Failed to save");
    } finally {
      setSubmitting(false);
    }
  };

  const handleDelete = async () => {
    if (!onDelete) return;
    if (!window.confirm("Delete this log? This cannot be undone.")) return;
    setDeleting(true);
    setError("");
    try {
      await onDelete();
    } catch (e: unknown) {
      setError(e instanceof Error ? e.message : "Failed to delete");
    } finally {
      setDeleting(false);
    }
  };

  const subtitleParts = [
    brand,
    category,
    servingSizeG ? `Serving ${servingSizeG}g` : null,
    loggedAt ? formatTimestamp(loggedAt) : null,
  ].filter(Boolean) as string[];

  return (
    <div className="page">
      <PageHeader title={title} onBack={onBack} backLabel={backLabel} />

      <div className="mb-5 flex flex-col gap-2">
        <h2 className="text-xl">{itemName}</h2>
        {(subtitleParts.length > 0 || customFoodEditPath) && (
          <p className="text-muted-foreground text-sm flex items-center flex-wrap gap-x-1.5">
            {subtitleParts.length > 0 && <span>{subtitleParts.join(" · ")}</span>}
            {customFoodEditPath && (
              <Link
                to={customFoodEditPath}
                className="text-primary font-medium underline-offset-2 hover:underline"
              >
                Edit food
              </Link>
            )}
          </p>
        )}
      </div>

      {error && <ErrorBanner message={error} />}

      <Card className="mb-5 overflow-hidden p-0">
        <FieldRow label="Meal">
          <Select
            value={values.slot}
            onValueChange={(v) => setValues((prev) => ({ ...prev, slot: v }))}
          >
            <SelectTrigger
              aria-label="Meal slot"
              className="text-muted-foreground font-semibold"
            >
              <SelectValue />
            </SelectTrigger>
            <SelectContent>
              <SelectItem value="__none__">None</SelectItem>
              {MEAL_SLOTS.map((s) => (
                <SelectItem key={s.value} value={s.value}>
                  {s.label}
                </SelectItem>
              ))}
            </SelectContent>
          </Select>
        </FieldRow>
        <FieldRow label="Amount">
          <NumberStepper
            value={values.amount}
            onChange={(v) => setValues((prev) => ({ ...prev, amount: v }))}
            min={0}
          />
        </FieldRow>
        <FieldRow label="Unit">
          <Select
            value={values.unit}
            onValueChange={(v) => setValues((prev) => ({ ...prev, unit: v }))}
          >
            <SelectTrigger
              aria-label="Unit"
              className="text-muted-foreground font-semibold"
            >
              <SelectValue />
            </SelectTrigger>
            <SelectContent>
              {unitOptions.map((u) => (
                <SelectItem key={u.code} value={u.code}>
                  {u.name === u.code ? u.code : `${u.name} (${u.code})`}
                </SelectItem>
              ))}
            </SelectContent>
          </Select>
        </FieldRow>
        <FieldRow label="Notes">
          <Input
            type="text"
            value={values.notes}
            placeholder="Optional notes"
            onChange={(e) => setValues((v) => ({ ...v, notes: e.target.value }))}
            className="text-right text-muted-foreground font-semibold border-0 bg-transparent px-0 shadow-none"
          />
        </FieldRow>
        <div className="flex flex-wrap gap-2.5 p-4 border-t border-border">
          <Button onClick={handleSubmit} disabled={submitting || deleting}>
            {submitting ? submittingLabel : submitLabel}
          </Button>
          {onDelete && (
            <Button
              variant="destructive"
              onClick={handleDelete}
              disabled={submitting || deleting}
            >
              {deleting ? "Deleting..." : "Delete"}
            </Button>
          )}
        </div>
      </Card>

      <section className="mb-5">
        <h2>Macro Breakdown</h2>
        <MacroBreakdown
          nutrients={computedNutrients.map((n) => ({ code: n.code, amount: n.amount }))}
        />
      </section>

      <section className="mb-5">
        <h2>Nutrients</h2>
        <NutrientsTable nutrients={computedNutrients} />
      </section>
    </div>
  );
}
