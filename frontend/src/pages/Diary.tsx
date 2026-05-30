import { useState, useEffect, useCallback } from "react";
import { Moon, Sun } from "lucide-react";
import { useNavigate, useSearchParams } from "react-router-dom";
import { useAuth } from "../hooks/AuthContext";
import { listLogs, getSummary } from "../api/logs";
import { getFoodDetail } from "../api/foods";
import type { LogResponse, SummaryEntry } from "../api/logs";
import { Skeleton } from "@/components/ui/skeleton";
import { Button } from "@/components/ui/button";
import {
  DropdownMenu,
  DropdownMenuTrigger,
  DropdownMenuContent,
  DropdownMenuItem,
} from "@/components/ui/dropdown-menu";
import { ErrorBanner } from "@/components/ErrorBanner";

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
  const protein = logs.reduce(
    (sum, log) => sum + getNutrientAmount(log.nutrients, "PROTEIN_G"),
    0,
  );
  const carbs = logs.reduce(
    (sum, log) => sum + getNutrientAmount(log.nutrients, "CARBS_G"),
    0,
  );
  const fat = logs.reduce(
    (sum, log) => sum + getNutrientAmount(log.nutrients, "FAT_G"),
    0,
  );
  const totalMacroCalories = protein * 4 + carbs * 4 + fat * 9;

  return {
    protein,
    carbs,
    fat,
    proteinPct: totalMacroCalories > 0 ? (protein * 4 / totalMacroCalories) * 100 : 0,
    carbsPct: totalMacroCalories > 0 ? (carbs * 4 / totalMacroCalories) * 100 : 0,
    fatPct: totalMacroCalories > 0 ? (fat * 9 / totalMacroCalories) * 100 : 0,
  };
}

function getNutrientVal(
  entries: SummaryEntry[],
  code: string,
): { amount: number; unit: string } | null {
  const entry = entries.find((n) => n.code === code);
  return entry
    ? { amount: parseAmount(entry.amount), unit: entry.unit }
    : null;
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
  const strokeWidth = 6;
  const radius = (size - strokeWidth) / 2;
  const circumference = 2 * Math.PI * radius;
  const pct = max > 0 ? Math.min(value / max, 1) : 0;
  const offset = circumference * (1 - pct);

  return (
    <div className="relative flex flex-col items-center min-w-0 p-1 rounded-[10px] bg-transparent border-0 shadow-none">
      <svg width={size} height={size} className="block">
        <circle
          cx={size / 2}
          cy={size / 2}
          r={radius}
          fill="none"
          stroke="hsl(var(--border))"
          strokeWidth={strokeWidth}
        />
        <circle
          cx={size / 2}
          cy={size / 2}
          r={radius}
          fill="none"
          stroke={color}
          strokeWidth={strokeWidth}
          strokeDasharray={circumference}
          strokeDashoffset={offset}
          transform={`rotate(-90 ${size / 2} ${size / 2})`}
          strokeLinecap="round"
        />
      </svg>
      <div className="absolute inset-0 flex items-center justify-center flex-col pointer-events-none">
        <span className="text-foreground text-base font-extrabold leading-tight">{Math.round(value)}</span>
        <span className="text-muted-foreground text-[0.625rem] font-bold uppercase">{unit}</span>
      </div>
      <span className="mt-1.5 text-muted-foreground text-xs font-bold">{label}</span>
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
  const macros = getMacroTotals(logs);

  return (
    <button
      type="button"
      className="inline-flex items-center flex-wrap w-fit max-w-full min-h-[24px] p-0 bg-transparent border-0 text-muted-foreground text-[0.8125rem] font-semibold text-left cursor-pointer"
      onClick={onToggle}
      title="Toggle macro grams and percentages"
    >
      carbs {mode === "grams" ? `${macros.carbs.toFixed(1)}g` : `${Math.round(macros.carbsPct)}%`}
      {" ⋅ "}
      protein {mode === "grams" ? `${macros.protein.toFixed(1)}g` : `${Math.round(macros.proteinPct)}%`}
      {" ⋅ "}
      fat {mode === "grams" ? `${macros.fat.toFixed(1)}g` : `${Math.round(macros.fatPct)}%`}
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
          logRes.items
            .filter((l) => l.item.type === "product")
            .map((l) => l.item.id),
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
        for (const d of details) {
          nameMap[d.id] = d.name;
        }
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
    if (formatDate(next) <= todayString()) {
      setCurrentDate(next);
    }
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
    logs
      .filter((l) => l.meal_slot === slot)
      .reduce((sum, l) => sum + getCalories(l.nutrients), 0);

  const handleLogout = async () => {
    await logout();
  };

  const renderLogRow = (log: LogResponse) => (
    <div key={log.id} className="flex items-stretch w-full bg-card border-b border-border last:border-b-0 hover:bg-accent/50">
      <button
        type="button"
        className="flex items-center flex-1 min-w-0 min-h-[56px] gap-2 p-3 bg-transparent border-0 text-foreground cursor-pointer text-left"
        onClick={() => navigate(`/logs/${log.id}`, { state: { editing: true } })}
      >
        <span className="flex-1 min-w-0 truncate font-medium">
          {foodNames[log.item.id] ?? "Loading..."}
        </span>
        <span className="text-muted-foreground text-sm font-semibold whitespace-nowrap">
          {log.quantity.amount} {log.quantity.unit}
        </span>
        <span className="min-w-[64px] text-right text-muted-foreground text-sm font-semibold whitespace-nowrap">
          {Math.round(getCalories(log.nutrients))} kcal
        </span>
      </button>

    </div>
  );

  return (
    <div className="w-full max-w-[760px] mx-auto p-4 pt-[calc(1rem+env(safe-area-inset-top))] pb-[calc(1.5rem+env(safe-area-inset-bottom))]">
      <header className="flex items-center justify-between gap-4 mb-4">
        <h1 className="min-w-0 overflow-hidden text-foreground text-[1.75rem] max-sm:text-[1.5rem] font-extrabold tracking-normal leading-tight text-ellipsis whitespace-nowrap">CalCo</h1>
        <div className="flex items-center gap-2">
          <Button
            variant="ghost"
            size="icon"
            onClick={() => setDarkMode((d) => !d)}
            aria-label="Toggle dark mode"
            title="Toggle dark mode"
          >
            {darkMode ? <Sun className="h-5 w-5" /> : <Moon className="h-5 w-5" />}
          </Button>
          <DropdownMenu>
          <DropdownMenuTrigger asChild>
            <Button
              variant="outline"
              className="rounded-full gap-2 pl-2 pr-1 flex items-center h-auto py-1"
              aria-label="Open profile menu"
            >
              <div className="w-[34px] h-[34px] rounded-full bg-primary text-primary-foreground text-[0.8125rem] font-extrabold flex items-center justify-center">
                {getInitials(displayName)}
              </div>
              <span className="text-muted-foreground text-sm font-bold max-w-[9rem] truncate">{displayName}</span>
            </Button>
          </DropdownMenuTrigger>
          <DropdownMenuContent align="end" className="w-[210px]">
            <DropdownMenuItem onClick={() => navigate("/meals")}>My Meals</DropdownMenuItem>
            <DropdownMenuItem className="text-destructive" onClick={handleLogout}>Logout</DropdownMenuItem>
          </DropdownMenuContent>
        </DropdownMenu>
      </div>
      </header>

      {error && <ErrorBanner message={error} />}

      <div className="flex flex-col gap-3.5 mb-4 p-3.5 bg-card border border-border rounded-[20px] shadow-sm">
        <div className="grid grid-cols-[44px_1fr_44px] items-center gap-3 p-0 bg-transparent border-0 rounded-none shadow-none">
          <Button variant="ghost" size="icon" className="rounded-full w-11 h-11 text-primary text-xl font-extrabold" onClick={goPrev}>
            ←
          </Button>
          <span className="min-w-0 overflow-hidden text-foreground text-base font-extrabold text-center text-ellipsis whitespace-nowrap">{displayDate(currentDate)}</span>
          <Button variant="ghost" size="icon" className="rounded-full w-11 h-11 text-primary text-xl font-extrabold" onClick={goNext} disabled={isToday}>
            →
          </Button>
        </div>

        <div className="grid grid-cols-4 max-sm:grid-cols-2 gap-1 mb-0 px-20 max-sm:gap-2">
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
      </div>

      <main className="flex flex-col gap-3">
        {loading && (
          <div className="flex flex-col gap-3">
            <Skeleton className="h-4 w-4/5" />
            <Skeleton className="h-4 w-3/5" />
            <Skeleton className="h-4 w-full" />
          </div>
        )}

        {!loading && logs.length === 0 && !error && (
          <p className="flex flex-col items-center justify-center gap-3.5 py-10 px-4 text-muted-foreground text-sm text-center">No food logged for this day.</p>
        )}

        {!loading &&
          mealSlotLogs.map(({ value, label, items }) => (
            <section key={value} className="bg-card border border-border rounded-xl shadow-sm overflow-hidden">
              <div className="flex items-center gap-3 p-3.5 bg-muted/50 border-b border-border">
                <div className="flex flex-1 flex-col gap-1 min-w-0">
                  <span className="text-foreground text-[1.0625rem] font-extrabold">{label}</span>
                  <SlotMacroSummary
                    logs={items}
                    mode={macroMode}
                    onToggle={() =>
                      setMacroMode((current) =>
                        current === "grams" ? "percent" : "grams",
                      )
                    }
                  />
                </div>
                <span className="flex-none text-muted-foreground text-sm font-extrabold whitespace-nowrap">
                  {Math.round(slotCalories(value))} kcal
                </span>
              </div>
              {items.length === 0 && (
                <p className="p-4 border-b border-border text-muted-foreground text-[0.9375rem] text-center">No items</p>
              )}
              {items.map((log) => renderLogRow(log))}
              <Button
                variant="ghost"
                className="w-full justify-start rounded-none h-12 border-t border-border text-primary font-extrabold"
                onClick={() =>
                  navigate("/search", {
                    state: { mealSlot: value },
                  })
                }
              >
                Add Food
              </Button>
            </section>
          ))}

        {!loading && otherLogs.length > 0 && (
          <section className="bg-card border border-border rounded-xl shadow-sm overflow-hidden">
            <div className="flex items-center gap-3 p-3.5 bg-muted/50 border-b border-border">
              <div className="flex flex-1 flex-col gap-1 min-w-0">
                <span className="text-foreground text-[1.0625rem] font-extrabold">Other</span>
                <SlotMacroSummary
                  logs={otherLogs}
                  mode={macroMode}
                  onToggle={() =>
                    setMacroMode((current) =>
                      current === "grams" ? "percent" : "grams",
                    )
                  }
                />
              </div>
              <span className="flex-none text-muted-foreground text-sm font-extrabold whitespace-nowrap">
                {Math.round(slotCalories(""))} kcal
              </span>
            </div>
            {otherLogs.map((log) => renderLogRow(log))}
          </section>
        )}
      </main>
    </div>
  );
}
