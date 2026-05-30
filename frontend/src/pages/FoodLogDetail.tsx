import { useState, useEffect } from "react";
import { useParams, useNavigate, useLocation } from "react-router-dom";
import { getLog, updateLog, deleteLog } from "../api/logs";
import { getFoodDetail } from "../api/foods";
import { getMeal } from "../api/meals";
import type { LogResponse } from "../api/logs";
import { Skeleton } from "@/components/ui/skeleton";
import { Button } from "@/components/ui/button";
import { Card } from "@/components/ui/card";
import { Input } from "@/components/ui/input";
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table";
import { ErrorBanner } from "@/components/ErrorBanner";
import { PageHeader } from "@/components/PageHeader";
import { FieldRow } from "@/components/FieldRow";
import { EmptyState } from "@/components/EmptyState";
import { MacroRing } from "@/components/MacroRing";

const MEAL_SLOTS = [
  { value: "breakfast", label: "Breakfast" },
  { value: "lunch", label: "Lunch" },
  { value: "dinner", label: "Dinner" },
  { value: "snack", label: "Snack" },
] as const;
const MACRO_COLORS = {
  protein: "hsl(var(--chart-2))",
  carbs: "hsl(var(--chart-3))",
  fat: "hsl(var(--chart-4))",
} as const;

function mealSlotLabel(value: string | null): string {
  if (!value) return "None";
  return MEAL_SLOTS.find((slot) => slot.value === value)?.label ?? value;
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

function parseAmount(val: string): number {
  const n = parseFloat(val);
  if (!isFinite(n) || n < 0) return 0;
  return n;
}

function getNutrientAmount(log: LogResponse, code: string): number {
  const entry = log.nutrients.find((n) => n.code === code);
  return entry ? parseAmount(entry.amount) : 0;
}

function getMacroBreakdown(log: LogResponse) {
  const protein = getNutrientAmount(log, "PROTEIN_G");
  const carbs = getNutrientAmount(log, "CARBS_G");
  const fat = getNutrientAmount(log, "FAT_G");
  const calories = getNutrientAmount(log, "ENERGY_KCAL");
  const totalKcal = protein * 4 + carbs * 4 + fat * 9;
  const pct = (kcal: number) => (totalKcal > 0 ? (kcal / totalKcal) * 100 : 0);
  return {
    calories,
    protein,
    carbs,
    fat,
    proteinPct: pct(protein * 4),
    carbsPct: pct(carbs * 4),
    fatPct: pct(fat * 9),
  };
}

function MacroBreakdown({ log }: { log: LogResponse }) {
  const m = getMacroBreakdown(log);
  return (
    <Card className="flex items-center gap-8 p-4">
      <MacroRing
        segments={[
          { value: m.proteinPct, color: MACRO_COLORS.protein },
          { value: m.carbsPct, color: MACRO_COLORS.carbs },
          { value: m.fatPct, color: MACRO_COLORS.fat },
        ]}
        total={100}
      >
        <span className="text-base font-extrabold leading-none">{Math.round(m.calories)}</span>
        <span className="text-muted-foreground text-xs font-bold">kcal</span>
      </MacroRing>
      <div className="grid grid-cols-3 flex-1">
        <MacroStat name="Protein" grams={m.protein} percent={m.proteinPct} color={MACRO_COLORS.protein} />
        <MacroStat name="Carbs" grams={m.carbs} percent={m.carbsPct} color={MACRO_COLORS.carbs} />
        <MacroStat name="Fat" grams={m.fat} percent={m.fatPct} color={MACRO_COLORS.fat} />
      </div>
    </Card>
  );
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
      <span className="text-xs font-bold" style={{ color }}>{Math.round(percent)}%</span>
      <span className="font-extrabold">{grams.toFixed(1)}g</span>
      <span className="text-muted-foreground text-xs font-bold">{name}</span>
    </div>
  );
}

async function fetchItemName(item: { type: string; id: string }): Promise<string> {
  try {
    if (item.type === "product") {
      const detail = await getFoodDetail(item.id);
      return detail.name;
    }
    if (item.type === "meal") {
      const meal = await getMeal(item.id);
      return meal.name;
    }
    return "Unknown item";
  } catch {
    return item.type === "meal" ? "Unknown meal" : "Unknown food";
  }
}

export function FoodLogDetail() {
  const { id } = useParams<{ id: string }>();
  const navigate = useNavigate();
  const location = useLocation();
  const startEditing = (location.state as { editing?: boolean } | null)?.editing ?? false;
  const [log, setLog] = useState<LogResponse | null>(null);
  const [foodName, setFoodName] = useState("");
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState("");
  const [editing, setEditing] = useState(startEditing);
  const [saving, setSaving] = useState(false);
  const [deleting, setDeleting] = useState(false);

  const [editQty, setEditQty] = useState("");
  const [editUnit, setEditUnit] = useState("");
  const [editSlot, setEditSlot] = useState("__none__");
  const [editNotes, setEditNotes] = useState("");

  useEffect(() => {
    if (!id) return;
    let cancelled = false;
    setLoading(true);
    setError("");
    getLog(id)
      .then(async (logRes) => {
        if (cancelled) return;
        setLog(logRes);
        setEditQty(logRes.quantity.amount);
        setEditUnit(logRes.quantity.unit);
        setEditSlot(logRes.meal_slot ?? "__none__");
        setEditNotes(logRes.notes ?? "");
        const name = await fetchItemName(logRes.item);
        if (!cancelled) setFoodName(name);
      })
      .catch((err: unknown) => {
        if (cancelled) return;
        setError(err instanceof Error ? err.message : "Failed to load log");
      })
      .finally(() => {
        if (!cancelled) setLoading(false);
      });

    return () => {
      cancelled = true;
    };
  }, [id]);

  const handleSave = async () => {
    if (!id || !log) return;
    setSaving(true);
    setError("");
    try {
      const updated = await updateLog(id, {
        quantity: { amount: editQty, unit: editUnit },
        meal_slot: editSlot === "__none__" ? null : editSlot,
        notes: editNotes || null,
      });
      setLog(updated);
      setEditing(false);
    } catch (err: unknown) {
      setError(err instanceof Error ? err.message : "Failed to update");
    } finally {
      setSaving(false);
    }
  };

  const handleDelete = async () => {
    if (!id) return;
    if (!window.confirm("Delete this food log? This cannot be undone.")) return;
    setDeleting(true);
    setError("");
    try {
      await deleteLog(id);
      navigate("/home", { replace: true });
    } catch (err: unknown) {
      setError(err instanceof Error ? err.message : "Failed to delete");
    } finally {
      setDeleting(false);
    }
  };

  const goHome = () => navigate("/home");

  if (loading) {
    return (
      <div className="page">
        <PageHeader title="Food Log" onBack={goHome} backLabel="Back to Diary" />
        <div className="flex flex-col gap-3">
          <Skeleton className="h-4 w-4/5" />
          <Skeleton className="h-4 w-3/5" />
          <Skeleton className="h-4 w-full" />
        </div>
      </div>
    );
  }

  if (error && !log) {
    return (
      <div className="page">
        <PageHeader title="Food Log" onBack={goHome} backLabel="Back to Diary" />
        <ErrorBanner message={error} />
      </div>
    );
  }

  if (!log) {
    return (
      <div className="page">
        <PageHeader title="Food Log" onBack={goHome} backLabel="Back to Diary" />
        <EmptyState>Log not found.</EmptyState>
      </div>
    );
  }

  const nutrientTable = (
    <Table>
      <TableHeader>
        <TableRow>
          <TableHead>Nutrient</TableHead>
          <TableHead className="text-right w-24">Amount</TableHead>
          <TableHead className="text-right w-24">Unit</TableHead>
        </TableRow>
      </TableHeader>
      <TableBody>
        {log.nutrients.map((n) => (
          <TableRow key={n.code}>
            <TableCell>{n.code.replace(/_/g, " ").toLowerCase()}</TableCell>
            <TableCell className="text-right">{parseFloat(n.amount).toFixed(1)}</TableCell>
            <TableCell className="text-right">{n.unit || "-"}</TableCell>
          </TableRow>
        ))}
      </TableBody>
    </Table>
  );

  return (
    <div className="page">
      <PageHeader
        title={editing ? "Edit Log" : "Food Log"}
        onBack={goHome}
        backLabel="Back to Diary"
      />

      {error && <ErrorBanner message={error} />}

      <div className="mb-5 flex flex-col gap-2">
        <h2 className="text-xl">{foodName || "Loading..."}</h2>
        <p className="text-muted-foreground text-sm font-semibold">
          {formatTimestamp(log.logged_at)}
        </p>
      </div>

      {editing ? (
        <>
          <Card className="mb-5 overflow-hidden p-0">
            <FieldRow label="Meal Slot">
              <select
                value={editSlot}
                onChange={(e) => setEditSlot(e.target.value)}
                className="input-select text-right text-muted-foreground font-semibold"
              >
                <option value="__none__">None</option>
                {MEAL_SLOTS.map((s) => (
                  <option key={s.value} value={s.value}>{s.label}</option>
                ))}
              </select>
            </FieldRow>
            <FieldRow label="Amount">
              <Input
                type="number"
                value={editQty}
                onChange={(e) => setEditQty(e.target.value)}
                min={0}
                step="any"
                className="text-right text-muted-foreground font-semibold border-0 bg-transparent px-0 shadow-none"
              />
            </FieldRow>
            <FieldRow label="Unit">
              <Input
                type="text"
                value={editUnit}
                onChange={(e) => setEditUnit(e.target.value)}
                className="text-right text-muted-foreground font-semibold border-0 bg-transparent px-0 shadow-none"
              />
            </FieldRow>
            <FieldRow label="Notes">
              <Input
                type="text"
                value={editNotes}
                onChange={(e) => setEditNotes(e.target.value)}
                placeholder="Optional notes"
                className="text-right text-muted-foreground font-semibold border-0 bg-transparent px-0 shadow-none"
              />
            </FieldRow>
            <div className="flex flex-wrap gap-2.5 p-4 border-t border-border">
              <Button onClick={handleSave} disabled={saving}>
                {saving ? "Saving..." : "Save"}
              </Button>
              <Button variant="destructive" onClick={handleDelete} disabled={deleting}>
                {deleting ? "Deleting..." : "Delete"}
              </Button>
            </div>
          </Card>

          <section className="mb-5">
            <h2>Macro Breakdown</h2>
            <MacroBreakdown log={log} />
          </section>

          <section className="mb-5">
            <h2>Nutrients</h2>
            {nutrientTable}
          </section>
        </>
      ) : (
        <>
          <section className="mb-5">
            <h2>Details</h2>
            <Table>
              <TableBody>
                <TableRow>
                  <TableCell className="font-medium">Meal Slot</TableCell>
                  <TableCell className="text-right">{mealSlotLabel(log.meal_slot)}</TableCell>
                </TableRow>
                <TableRow>
                  <TableCell className="font-medium">Quantity</TableCell>
                  <TableCell className="text-right">
                    {log.quantity.amount} {log.quantity.unit}
                  </TableCell>
                </TableRow>
                <TableRow>
                  <TableCell className="font-medium">Notes</TableCell>
                  <TableCell className="text-right">{log.notes || "-"}</TableCell>
                </TableRow>
              </TableBody>
            </Table>
          </section>

          <section className="mb-5">
            <h2>Macro Breakdown</h2>
            <MacroBreakdown log={log} />
          </section>

          <section className="mb-5">
            <h2>Nutrients</h2>
            {nutrientTable}
          </section>

          <div className="flex flex-wrap gap-2.5">
            <Button onClick={() => setEditing(true)}>Edit</Button>
            <Button variant="destructive" onClick={handleDelete} disabled={deleting}>
              {deleting ? "Deleting..." : "Delete"}
            </Button>
          </div>
        </>
      )}
    </div>
  );
}
