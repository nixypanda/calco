import { useMemo, useState } from "react";
import { Link } from "react-router-dom";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Card } from "@/components/ui/card";
import { ErrorBanner } from "@/components/ErrorBanner";
import { PageHeader } from "@/components/PageHeader";
import { FieldRow } from "@/components/FieldRow";
import { MacroBreakdown } from "@/components/MacroBreakdown";
import { NutrientsTable } from "@/components/NutrientsTable";
import { scaleNutrients } from "@/lib/scaleNutrients";
import type { ProductDetail, UnitItem } from "@/api/foods";
import type { NutrientSnapshotDto } from "@/api/logs";

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
          <select
            value={values.slot}
            onChange={(e) => setValues((v) => ({ ...v, slot: e.target.value }))}
            className="input-select text-right text-muted-foreground font-semibold"
          >
            <option value="__none__">None</option>
            {MEAL_SLOTS.map((s) => (
              <option key={s.value} value={s.value}>
                {s.label}
              </option>
            ))}
          </select>
        </FieldRow>
        <FieldRow label="Amount">
          <Input
            type="number"
            value={values.amount}
            min={0}
            step="any"
            onChange={(e) => setValues((v) => ({ ...v, amount: e.target.value }))}
            className="text-right text-muted-foreground font-semibold border-0 bg-transparent px-0 shadow-none"
          />
        </FieldRow>
        <FieldRow label="Unit">
          <select
            value={values.unit}
            onChange={(e) => setValues((v) => ({ ...v, unit: e.target.value }))}
            className="input-select text-right text-muted-foreground font-semibold"
          >
            {unitOptions.map((u) => (
              <option key={u.code} value={u.code}>
                {u.name === u.code ? u.code : `${u.name} (${u.code})`}
              </option>
            ))}
          </select>
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
