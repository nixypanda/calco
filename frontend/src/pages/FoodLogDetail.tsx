import { useState, useEffect } from "react";
import { useParams, useNavigate, useLocation } from "react-router-dom";
import { getLog, updateLog, deleteLog } from "../api/logs";
import { getFoodDetail } from "../api/foods";
import { getMeal } from "../api/meals";
import type { LogResponse } from "../api/logs";
import { Skeleton } from "@/components/ui/skeleton";
import { Button } from "@/components/ui/button";
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
  const macroCalories = protein * 4 + carbs * 4 + fat * 9;

  return {
    calories,
    protein,
    carbs,
    fat,
    proteinPct: macroCalories > 0 ? (protein * 4 / macroCalories) * 100 : 0,
    carbsPct: macroCalories > 0 ? (carbs * 4 / macroCalories) * 100 : 0,
    fatPct: macroCalories > 0 ? (fat * 9 / macroCalories) * 100 : 0,
  };
}

function MacroDonut({ log }: { log: LogResponse }) {
  const macros = getMacroBreakdown(log);
  const size = 80;
  const strokeWidth = 6;
  const radius = (size - strokeWidth) / 2;
  const circumference = 2 * Math.PI * radius;
  const totalPct = macros.proteinPct + macros.carbsPct + macros.fatPct;
  const hasData = totalPct > 0;
  const proteinLen = hasData ? (macros.proteinPct / 100) * circumference : 0;
  const carbsLen = hasData ? (macros.carbsPct / 100) * circumference : 0;
  const fatLen = hasData ? (macros.fatPct / 100) * circumference : 0;

  return (
    <div className="flex items-center gap-16 px-20 py-4 bg-card border border-border rounded-xl shadow-sm max-sm:flex-row max-sm:items-center">
      <div className="relative grid place-items-center w-20 h-20 flex-none rounded-full self-center">
        <svg width={size} height={size} className="absolute inset-0 w-full h-full rounded-full">
          <circle
            cx={size / 2}
            cy={size / 2}
            r={radius}
            fill="none"
            stroke="hsl(var(--border))"
            strokeWidth={strokeWidth}
          />
          {hasData && (
            <>
              <circle
                cx={size / 2}
                cy={size / 2}
                r={radius}
                fill="none"
                stroke={MACRO_COLORS.protein}
                strokeWidth={strokeWidth}
                strokeDasharray={`${proteinLen} ${circumference - proteinLen}`}
                strokeDashoffset={0}
                transform={`rotate(-90 ${size / 2} ${size / 2})`}
              />
              <circle
                cx={size / 2}
                cy={size / 2}
                r={radius}
                fill="none"
                stroke={MACRO_COLORS.carbs}
                strokeWidth={strokeWidth}
                strokeDasharray={`${carbsLen} ${circumference - carbsLen}`}
                strokeDashoffset={-proteinLen}
                transform={`rotate(-90 ${size / 2} ${size / 2})`}
              />
              <circle
                cx={size / 2}
                cy={size / 2}
                r={radius}
                fill="none"
                stroke={MACRO_COLORS.fat}
                strokeWidth={strokeWidth}
                strokeDasharray={`${fatLen} ${circumference - fatLen}`}
                strokeDashoffset={-(proteinLen + carbsLen)}
                transform={`rotate(-90 ${size / 2} ${size / 2})`}
              />
            </>
          )}
        </svg>
        <div className="flex items-center justify-center flex-col w-auto h-auto bg-transparent rounded-none">
          <span className="text-foreground text-base font-extrabold leading-none">
            {Math.round(macros.calories)}
          </span>
          <span className="text-muted-foreground text-xs font-bold">kcal</span>
        </div>
      </div>
      <div className="grid grid-cols-3 max-sm:grid-cols-3 gap-0 flex-1">
        <MacroStat name="Protein" grams={macros.protein} percent={macros.proteinPct} color={MACRO_COLORS.protein} />
        <MacroStat name="Carbs" grams={macros.carbs} percent={macros.carbsPct} color={MACRO_COLORS.carbs} />
        <MacroStat name="Fat" grams={macros.fat} percent={macros.fatPct} color={MACRO_COLORS.fat} />
      </div>
    </div>
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
    <div className="flex flex-col gap-[0.0625rem] min-w-0 p-[0.1875rem] bg-transparent border-l-[3px] text-center" style={{ borderColor: color }}>
      <span className="text-xs font-bold" style={{ color }}>{Math.round(percent)}%</span>
      <span className="text-foreground text-[0.9375rem] font-extrabold">{grams.toFixed(1)}g</span>
      <span className="text-muted-foreground text-xs font-bold">{name}</span>
    </div>
  );
}

function Header({ title, onBack }: { title: string; onBack: () => void }) {
  return (
    <header className="flex items-center justify-between gap-4 mb-4">
      <div className="flex items-center gap-2.5 min-w-0">
        <button
          className="inline-flex items-center justify-center min-w-[44px] min-h-[44px] pr-2 bg-transparent border-0 rounded-xl text-muted-foreground cursor-pointer text-base font-bold hover:bg-accent"
          onClick={onBack}
          aria-label="Back to Diary"
        >
          <span aria-hidden="true" className="text-[2rem] leading-[0.8]">‹</span>
        </button>
        <h1 className="text-foreground text-[1.75rem] max-sm:text-[1.5rem] font-extrabold">{title}</h1>
      </div>
    </header>
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
  const startEditing =
    (location.state as { editing?: boolean } | null)?.editing ?? false;
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
  const wrapperClass = "w-full max-w-[760px] mx-auto p-4 pt-[calc(1rem+env(safe-area-inset-top))] pb-[calc(1.5rem+env(safe-area-inset-bottom))]";

  if (loading) {
    return (
      <div className={wrapperClass}>
        <Header title="Food Log" onBack={goHome} />
        <main>
          <div className="flex flex-col gap-3">
            <Skeleton className="h-4 w-4/5" />
            <Skeleton className="h-4 w-3/5" />
            <Skeleton className="h-4 w-full" />
          </div>
        </main>
      </div>
    );
  }

  if (error && !log) {
    return (
      <div className={wrapperClass}>
        <Header title="Food Log" onBack={goHome} />
        <main><ErrorBanner message={error} /></main>
      </div>
    );
  }

  if (!log) {
    return (
      <div className={wrapperClass}>
        <Header title="Food Log" onBack={goHome} />
        <main>
          <p className="flex flex-col items-center justify-center gap-3.5 py-10 px-4 text-muted-foreground text-sm text-center">Log not found.</p>
        </main>
      </div>
    );
  }

  const selectClass = "flex h-9 w-full rounded-md border border-input bg-transparent px-3 py-1 text-base shadow-sm focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring disabled:cursor-not-allowed disabled:opacity-50 md:text-sm text-right text-muted-foreground font-semibold";

  return (
    <div className={wrapperClass}>
      <Header title={editing ? "Edit Log" : "Food Log"} onBack={goHome} />

      <main>
        {error && <ErrorBanner message={error} />}

        <div className="mb-5 flex flex-col gap-2">
          <h2 className="mb-1 text-foreground text-xl font-extrabold">{foodName || "Loading..."}</h2>
          <p className="text-muted-foreground text-sm font-semibold">{formatTimestamp(log.logged_at)}</p>
        </div>

        {editing ? (
          <>
            <section className="mb-5">
              <div className="bg-card border border-border rounded-xl shadow-sm overflow-hidden">
                <label className="grid grid-cols-[minmax(96px,0.8fr)_minmax(0,1.4fr)] items-center gap-4 min-h-[56px] p-2.5 border-b border-border last:border-b-0 max-sm:grid-cols-[minmax(82px,0.7fr)_minmax(0,1.3fr)] max-sm:gap-3">
                  <span>Meal Slot</span>
                  <select
                    value={editSlot}
                    onChange={(e) => setEditSlot(e.target.value)}
                    className={selectClass}
                  >
                    <option value="__none__">None</option>
                    {MEAL_SLOTS.map((s) => (
                      <option key={s.value} value={s.value}>{s.label}</option>
                    ))}
                  </select>
                </label>
                <label className="grid grid-cols-[minmax(96px,0.8fr)_minmax(0,1.4fr)] items-center gap-4 min-h-[56px] p-2.5 border-b border-border last:border-b-0 max-sm:grid-cols-[minmax(82px,0.7fr)_minmax(0,1.3fr)] max-sm:gap-3">
                  <span>Amount</span>
                  <Input
                    type="number"
                    value={editQty}
                    onChange={(e) => setEditQty(e.target.value)}
                    min={0}
                    step="any"
                    className="text-right text-muted-foreground font-semibold border-0 bg-transparent h-[38px] px-0"
                  />
                </label>
                <label className="grid grid-cols-[minmax(96px,0.8fr)_minmax(0,1.4fr)] items-center gap-4 min-h-[56px] p-2.5 border-b border-border last:border-b-0 max-sm:grid-cols-[minmax(82px,0.7fr)_minmax(0,1.3fr)] max-sm:gap-3">
                  <span>Unit</span>
                  <Input
                    type="text"
                    value={editUnit}
                    onChange={(e) => setEditUnit(e.target.value)}
                    className="text-right text-muted-foreground font-semibold border-0 bg-transparent h-[38px] px-0"
                  />
                </label>
                <label className="grid grid-cols-[minmax(96px,0.8fr)_minmax(0,1.4fr)] items-center gap-4 min-h-[56px] p-2.5 border-b border-border last:border-b-0 max-sm:grid-cols-[minmax(82px,0.7fr)_minmax(0,1.3fr)] max-sm:gap-3">
                  <span>Notes</span>
                  <Input
                    type="text"
                    value={editNotes}
                    onChange={(e) => setEditNotes(e.target.value)}
                    placeholder="Optional notes"
                    className="text-right text-muted-foreground font-semibold border-0 bg-transparent h-[38px] px-0"
                  />
                </label>
                <div className="flex flex-wrap gap-2.5 p-3.5 border-t border-border">
                  <Button onClick={handleSave} disabled={saving}>
                    {saving ? "Saving..." : "Save"}
                  </Button>
                  <Button variant="destructive" onClick={handleDelete} disabled={deleting}>
                    {deleting ? "Deleting..." : "Delete"}
                  </Button>
                </div>
              </div>
            </section>

            <section className="mb-5">
              <h2>Macro Breakdown</h2>
              <MacroDonut log={log} />
            </section>

            <section className="mb-5">
              <h2>Nutrients</h2>
              <Table>
                <TableHeader>
                  <TableRow>
                    <TableHead>Nutrient</TableHead>
                    <TableHead className="text-right w-[92px]">Amount</TableHead>
                    <TableHead className="text-right w-[92px]">Unit</TableHead>
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
                    <TableCell className="text-right">{log.quantity.amount} {log.quantity.unit}</TableCell>
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
              <MacroDonut log={log} />
            </section>

            <section className="mb-5">
              <h2>Nutrients</h2>
              <Table>
                <TableHeader>
                  <TableRow>
                    <TableHead>Nutrient</TableHead>
                    <TableHead className="text-right w-[92px]">Amount</TableHead>
                    <TableHead className="text-right w-[92px]">Unit</TableHead>
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
            </section>

            <div className="flex flex-wrap gap-2.5">
              <Button onClick={() => setEditing(true)}>Edit</Button>
              <Button variant="destructive" onClick={handleDelete} disabled={deleting}>
                {deleting ? "Deleting..." : "Delete"}
              </Button>
            </div>
          </>
        )}
      </main>
    </div>
  );
}
