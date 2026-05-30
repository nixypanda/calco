import { useState, useEffect, useCallback, useRef } from "react";
import { Moon, Sun } from "lucide-react";
import { useNavigate, useSearchParams } from "react-router-dom";
import { useAuth } from "../hooks/AuthContext";
import { listLogs, getSummary } from "../api/logs";
import { getFoodDetail } from "../api/foods";
import type { LogResponse, SummaryEntry } from "../api/logs";
import { Skeleton } from "@/components/ui/skeleton";
import { Button } from "@/components/ui/button";
import { Card } from "@/components/ui/card";
import {
  DropdownMenu,
  DropdownMenuTrigger,
  DropdownMenuContent,
  DropdownMenuItem,
} from "@/components/ui/dropdown-menu";
import { ErrorBanner } from "@/components/ErrorBanner";
import { EmptyState } from "@/components/EmptyState";
import { MacroRing } from "@/components/MacroRing";

const MEAL_SLOTS = [
  { value: "breakfast", label: "Breakfast" },
  { value: "lunch", label: "Lunch" },
  { value: "dinner", label: "Dinner" },
  { value: "snack", label: "Snack" },
] as const;
const SUMMARY_CODES = "ENERGY_KCAL,PROTEIN_G,CARBS_G,FAT_G";
const DEFAULT_CALORIE_GOAL = 2000;
const MACRO_COLORS = {
  calories: "hsl(var(--chart-1))",
  protein: "hsl(var(--chart-2))",
  carbs: "hsl(var(--chart-3))",
  fat: "hsl(var(--chart-4))",
} as const;

function formatDate(date: Date): string {
  const y = date.getFullYear();
  const m = String(date.getMonth() + 1).padStart(2, "0");
  const d = String(date.getDate()).padStart(2, "0");
  return `${y}-${m}-${d}`;
}

function displayDate(date: Date): string {
  return date.toLocaleDateString("en-US", {
    weekday: "short",
    month: "short",
    day: "numeric",
  });
}

function parseAmount(val: string): number {
  const n = parseFloat(val);
  if (!isFinite(n) || n < 0) return 0;
  return n;
}

function getCalories(nutrients: { code: string; amount: string }[]): number {
  const entry = nutrients.find((n) => n.code === "ENERGY_KCAL");
  return entry ? parseAmount(entry.amount) : 0;
}

function getNutrientAmount(
  nutrients: { code: string; amount: string }[],
  code: string,
): number {
  const entry = nutrients.find((n) => n.code === code);
  return entry ? parseAmount(entry.amount) : 0;
}

function getMacroTotals(logs: LogResponse[]) {
  const protein = logs.reduce((s, l) => s + getNutrientAmount(l.nutrients, "PROTEIN_G"), 0);
  const carbs = logs.reduce((s, l) => s + getNutrientAmount(l.nutrients, "CARBS_G"), 0);
  const fat = logs.reduce((s, l) => s + getNutrientAmount(l.nutrients, "FAT_G"), 0);
  const total = protein * 4 + carbs * 4 + fat * 9;
  const pct = (kcal: number) => (total > 0 ? (kcal / total) * 100 : 0);
  return {
    protein,
    carbs,
    fat,
    proteinPct: pct(protein * 4),
    carbsPct: pct(carbs * 4),
    fatPct: pct(fat * 9),
  };
}

function getNutrientVal(
  entries: SummaryEntry[],
  code: string,
): { amount: number; unit: string } | null {
  const entry = entries.find((n) => n.code === code);
  return entry ? { amount: parseAmount(entry.amount), unit: entry.unit } : null;
}

function NutrientRing({
  label,
  value,
  unit,
  max,
  color,
  size = 80,
}: {
  label: string;
  value: number;
  unit: string;
  max: number;
  color: string;
  size?: number;
}) {
  const big = size >= 120;
  return (
    <div className="flex flex-col items-center">
      <MacroRing segments={[{ value, color }]} total={max} size={size} strokeWidth={big ? 10 : 6}>
        <span className={big ? "text-3xl font-extrabold leading-tight" : "text-base font-extrabold leading-tight"}>
          {Math.round(value)}
        </span>
        <span className={`text-muted-foreground font-bold uppercase ${big ? "text-xs" : "text-[0.625rem]"}`}>
          {unit}
        </span>
      </MacroRing>
      <span className={`mt-1.5 text-muted-foreground font-bold ${big ? "text-sm" : "text-xs"}`}>{label}</span>
    </div>
  );
}

function SlotMacroSummary({
  logs,
  mode,
  onToggle,
}: {
  logs: LogResponse[];
  mode: "grams" | "percent";
  onToggle: () => void;
}) {
  const m = getMacroTotals(logs);
  const fmt = (g: number, p: number) =>
    mode === "grams" ? `${g.toFixed(1)}g` : `${Math.round(p)}%`;
  return (
    <button
      type="button"
      onClick={onToggle}
      title="Toggle macro grams and percentages"
      className="text-left text-muted-foreground text-sm font-semibold"
    >
      <span className="hidden sm:inline">
        carbs {fmt(m.carbs, m.carbsPct)} ⋅ protein {fmt(m.protein, m.proteinPct)} ⋅ fat {fmt(m.fat, m.fatPct)}
      </span>
      <span className="sm:hidden">
        C {fmt(m.carbs, m.carbsPct)} ⋅ P {fmt(m.protein, m.proteinPct)} ⋅ F {fmt(m.fat, m.fatPct)}
      </span>
    </button>
  );
}

function todayString(): string {
  return new Date().toISOString().slice(0, 10);
}

function getInitials(name: string): string {
  const words = name.trim().split(/\s+/).filter(Boolean);
  if (words.length === 0) return "?";
  if (words.length === 1) return words[0].slice(0, 2).toUpperCase();
  return `${words[0][0]}${words[1][0]}`.toUpperCase();
}

export function Diary() {
  const navigate = useNavigate();
  const [searchParams] = useSearchParams();
  const { identity, profile, logout } = useAuth();

  const getInitialDate = (): Date => {
    const dateParam = searchParams.get("date");
    if (dateParam) {
      const d = new Date(dateParam + "T00:00:00");
      if (!isNaN(d.getTime())) return d;
    }
    const now = new Date();
    now.setHours(0, 0, 0, 0);
    return now;
  };

  const [currentDate, setCurrentDate] = useState(getInitialDate);
  const [logs, setLogs] = useState<LogResponse[]>([]);
  const [summary, setSummary] = useState<SummaryEntry[]>([]);
  const [foodNames, setFoodNames] = useState<Record<string, string>>({});
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState("");
  const [macroMode, setMacroMode] = useState<"grams" | "percent">("grams");
  const [ringTile, setRingTile] = useState(0);
  const ringScrollRef = useRef<HTMLDivElement>(null);
  const [darkMode, setDarkMode] = useState(() => {
    const stored = localStorage.getItem("theme");
    if (stored === "dark") return true;
    if (stored === "light") return false;
    return window.matchMedia?.("(prefers-color-scheme: dark)").matches ?? false;
  });

  useEffect(() => {
    document.documentElement.classList.toggle("dark", darkMode);
    localStorage.setItem("theme", darkMode ? "dark" : "light");
  }, [darkMode]);

  const dateStr = formatDate(currentDate);
  const displayName = profile?.display_name ?? identity?.username ?? "User";

  const fetchData = useCallback(async () => {
    setLoading(true);
    setError("");
    try {
      const [logRes, summaryRes] = await Promise.all([
        listLogs(dateStr, dateStr),
        getSummary(dateStr, dateStr, SUMMARY_CODES),
      ]);
      setLogs(logRes.items);
      setSummary(summaryRes.totals);

      const productIds = [
        ...new Set(
          logRes.items.filter((l) => l.item.type === "product").map((l) => l.item.id),
        ),
      ];
      if (productIds.length > 0) {
        const details = await Promise.all(
          productIds.map((id) =>
            getFoodDetail(id)
              .then((d) => ({ id: d.id, name: d.name }))
              .catch(() => ({ id, name: "Unknown food" })),
          ),
        );
        const nameMap: Record<string, string> = {};
        for (const d of details) nameMap[d.id] = d.name;
        setFoodNames(nameMap);
      } else {
        setFoodNames({});
      }
    } catch (err: unknown) {
      setError(err instanceof Error ? err.message : "Failed to load diary");
    } finally {
      setLoading(false);
    }
  }, [dateStr]);

  useEffect(() => {
    fetchData();
  }, [fetchData]);

  const goPrev = () => {
    const prev = new Date(currentDate);
    prev.setDate(prev.getDate() - 1);
    setCurrentDate(prev);
  };

  const goNext = () => {
    const next = new Date(currentDate);
    next.setDate(next.getDate() + 1);
    if (formatDate(next) <= todayString()) setCurrentDate(next);
  };

  const isToday = dateStr === todayString();
  const kcal = getNutrientVal(summary, "ENERGY_KCAL");
  const protein = getNutrientVal(summary, "PROTEIN_G");
  const carbs = getNutrientVal(summary, "CARBS_G");
  const fat = getNutrientVal(summary, "FAT_G");

  const mealSlotLogs = MEAL_SLOTS.map((slot) => ({
    ...slot,
    items: logs.filter((l) => l.meal_slot === slot.value),
  }));
  const otherLogs = logs.filter((l) => !l.meal_slot);

  const slotCalories = (slot: string) =>
    logs.filter((l) => l.meal_slot === slot).reduce((s, l) => s + getCalories(l.nutrients), 0);

  const toggleMacroMode = () =>
    setMacroMode((c) => (c === "grams" ? "percent" : "grams"));

  const renderLogRow = (log: LogResponse) => (
    <button
      key={log.id}
      type="button"
      onClick={() => navigate(`/logs/${log.id}`, { state: { editing: true } })}
      className="flex items-center w-full min-h-14 gap-2 p-3 text-left border-b border-border last:border-b-0 hover:bg-accent/50"
    >
      <span className="flex-1 min-w-0 truncate font-medium">
        {foodNames[log.item.id] ?? "Loading..."}
      </span>
      <span className="text-muted-foreground text-sm font-semibold whitespace-nowrap">
        {log.quantity.amount} {log.quantity.unit}
      </span>
      <span className="min-w-16 text-right text-muted-foreground text-sm font-semibold whitespace-nowrap">
        {Math.round(getCalories(log.nutrients))} kcal
      </span>
    </button>
  );

  return (
    <div className="page">
      <header className="flex items-center justify-between gap-4 mb-4">
        <h1>CalCo</h1>
        <div className="flex items-center gap-2">
          <Button
            variant="ghost"
            size="icon"
            onClick={() => setDarkMode((d) => !d)}
            aria-label="Toggle dark mode"
          >
            {darkMode ? <Sun className="h-5 w-5" /> : <Moon className="h-5 w-5" />}
          </Button>
          <DropdownMenu>
            <DropdownMenuTrigger asChild>
              <Button
                variant="outline"
                className="rounded-full gap-2 pl-2 pr-3 h-auto py-1"
                aria-label="Open profile menu"
              >
                <div className="w-8 h-8 rounded-full bg-primary text-primary-foreground text-xs font-extrabold flex items-center justify-center">
                  {getInitials(displayName)}
                </div>
                <span className="text-muted-foreground text-sm font-bold max-w-36 truncate">
                  {displayName}
                </span>
              </Button>
            </DropdownMenuTrigger>
            <DropdownMenuContent align="end" className="w-52">
              <DropdownMenuItem onClick={() => navigate("/meals")}>My Meals</DropdownMenuItem>
              <DropdownMenuItem className="text-destructive" onClick={() => logout()}>
                Logout
              </DropdownMenuItem>
            </DropdownMenuContent>
          </DropdownMenu>
        </div>
      </header>

      {error && <ErrorBanner message={error} />}

      <Card className="flex flex-col gap-4 p-4 mb-4">
        <div className="grid grid-cols-[44px_1fr_44px] items-center gap-3">
          <Button variant="ghost" size="icon" onClick={goPrev} aria-label="Previous day">
            <span className="text-xl font-extrabold">←</span>
          </Button>
          <span className="text-center font-extrabold truncate">{displayDate(currentDate)}</span>
          <Button
            variant="ghost"
            size="icon"
            onClick={goNext}
            disabled={isToday}
            aria-label="Next day"
          >
            <span className="text-xl font-extrabold">→</span>
          </Button>
        </div>

        <div className="hidden sm:grid sm:grid-cols-4 gap-1 px-20">
          <NutrientRing
            label="Calories"
            value={kcal?.amount ?? 0}
            unit={kcal?.unit ?? "kcal"}
            max={DEFAULT_CALORIE_GOAL}
            color={MACRO_COLORS.calories}
          />
          <NutrientRing
            label="Protein"
            value={protein?.amount ?? 0}
            unit={protein?.unit ?? "g"}
            max={150}
            color={MACRO_COLORS.protein}
          />
          <NutrientRing
            label="Carbs"
            value={carbs?.amount ?? 0}
            unit={carbs?.unit ?? "g"}
            max={250}
            color={MACRO_COLORS.carbs}
          />
          <NutrientRing
            label="Fat"
            value={fat?.amount ?? 0}
            unit={fat?.unit ?? "g"}
            max={65}
            color={MACRO_COLORS.fat}
          />
        </div>

        <div className="sm:hidden flex flex-col gap-3">
          <div
            ref={ringScrollRef}
            onScroll={(e) => {
              const el = e.currentTarget;
              setRingTile(Math.round(el.scrollLeft / el.clientWidth));
            }}
            className="flex overflow-x-auto snap-x snap-mandatory [scrollbar-width:none] [&::-webkit-scrollbar]:hidden"
          >
            <div className="snap-center shrink-0 w-full flex justify-center py-2">
              <NutrientRing
                label="Calories"
                value={kcal?.amount ?? 0}
                unit={kcal?.unit ?? "kcal"}
                max={DEFAULT_CALORIE_GOAL}
                color={MACRO_COLORS.calories}
                size={140}
              />
            </div>
            <div className="snap-center shrink-0 w-full flex justify-around py-2">
              <NutrientRing
                label="Protein"
                value={protein?.amount ?? 0}
                unit={protein?.unit ?? "g"}
                max={150}
                color={MACRO_COLORS.protein}
              />
              <NutrientRing
                label="Carbs"
                value={carbs?.amount ?? 0}
                unit={carbs?.unit ?? "g"}
                max={250}
                color={MACRO_COLORS.carbs}
              />
              <NutrientRing
                label="Fat"
                value={fat?.amount ?? 0}
                unit={fat?.unit ?? "g"}
                max={65}
                color={MACRO_COLORS.fat}
              />
            </div>
          </div>
          <div className="flex justify-center gap-1.5">
            {[0, 1].map((i) => (
              <button
                key={i}
                type="button"
                aria-label={i === 0 ? "Show calories" : "Show macros"}
                onClick={() => {
                  const el = ringScrollRef.current;
                  if (el) el.scrollTo({ left: i * el.clientWidth, behavior: "smooth" });
                }}
                className={`h-1.5 w-1.5 rounded-full transition-colors ${
                  ringTile === i ? "bg-foreground" : "bg-border"
                }`}
              />
            ))}
          </div>
        </div>
      </Card>

      <main className="flex flex-col gap-3">
        {loading && (
          <div className="flex flex-col gap-3">
            <Skeleton className="h-4 w-4/5" />
            <Skeleton className="h-4 w-3/5" />
            <Skeleton className="h-4 w-full" />
          </div>
        )}

        {!loading && logs.length === 0 && !error && (
          <EmptyState>No food logged for this day.</EmptyState>
        )}

        {!loading &&
          mealSlotLogs.map(({ value, label, items }) => (
            <Card key={value} className="overflow-hidden p-0">
              <div className="flex items-center gap-3 p-4 bg-muted/50 border-b border-border">
                <div className="flex flex-1 flex-col gap-1 min-w-0">
                  <span className="font-extrabold">{label}</span>
                  <SlotMacroSummary logs={items} mode={macroMode} onToggle={toggleMacroMode} />
                </div>
                <span className="text-muted-foreground text-sm font-extrabold whitespace-nowrap">
                  {Math.round(slotCalories(value))} kcal
                </span>
              </div>
              {items.length === 0 ? (
                <p className="p-4 text-muted-foreground text-center">No items</p>
              ) : (
                items.map(renderLogRow)
              )}
              <Button
                variant="ghost"
                className="w-full justify-start rounded-none h-12 border-t border-border text-primary font-extrabold"
                onClick={() => navigate("/search", { state: { mealSlot: value } })}
              >
                Add Food
              </Button>
            </Card>
          ))}

        {!loading && otherLogs.length > 0 && (
          <Card className="overflow-hidden p-0">
            <div className="flex items-center gap-3 p-4 bg-muted/50 border-b border-border">
              <div className="flex flex-1 flex-col gap-1 min-w-0">
                <span className="font-extrabold">Other</span>
                <SlotMacroSummary logs={otherLogs} mode={macroMode} onToggle={toggleMacroMode} />
              </div>
              <span className="text-muted-foreground text-sm font-extrabold whitespace-nowrap">
                {Math.round(slotCalories(""))} kcal
              </span>
            </div>
            {otherLogs.map(renderLogRow)}
          </Card>
        )}
      </main>
    </div>
  );
}
