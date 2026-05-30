import { useState, useEffect, useCallback } from "react";
import { useNavigate, useSearchParams } from "react-router-dom";
import { useAuth } from "../hooks/AuthContext";
import { listLogs, getSummary } from "../api/logs";
import { getFoodDetail } from "../api/foods";
import type { LogResponse, SummaryEntry } from "../api/logs";

const MEAL_SLOTS = ["Breakfast", "Lunch", "Dinner", "Snack"] as const;
const SUMMARY_CODES = "ENERGY_KCAL,PROTEIN_G,CARBS_G,FAT_G";
const DEFAULT_CALORIE_GOAL = 2000;

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
  return isNaN(n) ? 0 : n;
}

function getCalories(nutrients: { code: string; amount: string }[]): number {
  const entry = nutrients.find((n) => n.code === "ENERGY_KCAL");
  return entry ? parseAmount(entry.amount) : 0;
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
    <div className="nutrient-ring-wrapper">
      <svg width={size} height={size} className="nutrient-ring-svg">
        <circle
          cx={size / 2}
          cy={size / 2}
          r={radius}
          fill="none"
          stroke="#e5e5e5"
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
      <div className="ring-center">
        <span className="ring-value">{Math.round(value)}</span>
        <span className="ring-unit">{unit}</span>
      </div>
      <span className="ring-label">{label}</span>
    </div>
  );
}

function todayString(): string {
  return new Date().toISOString().slice(0, 10);
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

  const dateStr = formatDate(currentDate);

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
            getFoodDetail(id).catch(() => null),
          ),
        );
        const nameMap: Record<string, string> = {};
        for (const d of details) {
          if (d) nameMap[d.id] = d.name;
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
    slot,
    items: logs.filter((l) => l.meal_slot === slot),
  }));
  const otherLogs = logs.filter((l) => !l.meal_slot);

  const slotCalories = (slot: string) =>
    logs
      .filter((l) => l.meal_slot === slot)
      .reduce((sum, l) => sum + getCalories(l.nutrients), 0);

  return (
    <div className="diary-page">
      <header>
        <h1>CalCo</h1>
        <div className="header-right">
          <span>
            Welcome,{" "}
            <strong>{profile?.display_name ?? identity?.username}</strong>
          </span>
          <button onClick={logout}>Logout</button>
        </div>
      </header>

      <nav className="diary-nav">
        <button className="btn-secondary" onClick={() => navigate("/search")}>
          Search Foods
        </button>
        <button
          className="btn-secondary"
          onClick={() => navigate("/foods/custom/new")}
        >
          Create Food
        </button>
        <button className="btn-secondary" onClick={() => navigate("/history")}>
          History
        </button>
        <button className="btn-secondary" onClick={() => navigate("/meals")}>
          Meals
        </button>
      </nav>

      <div className="date-selector">
        <button className="date-arrow" onClick={goPrev}>
          ←
        </button>
        <span className="date-label">{displayDate(currentDate)}</span>
        <button className="date-arrow" onClick={goNext} disabled={isToday}>
          →
        </button>
      </div>

      {error && <p className="error">{error}</p>}

      <div className="summary-rings">
        <NutrientRing
          label="Calories"
          value={kcal?.amount ?? 0}
          unit={kcal?.unit ?? "kcal"}
          max={DEFAULT_CALORIE_GOAL}
          color="#16a34a"
        />
        <NutrientRing
          label="Protein"
          value={protein?.amount ?? 0}
          unit={protein?.unit ?? "g"}
          max={150}
          color="#3b82f6"
        />
        <NutrientRing
          label="Carbs"
          value={carbs?.amount ?? 0}
          unit={carbs?.unit ?? "g"}
          max={250}
          color="#f59e0b"
        />
        <NutrientRing
          label="Fat"
          value={fat?.amount ?? 0}
          unit={fat?.unit ?? "g"}
          max={65}
          color="#f43f5e"
        />
      </div>

      <main className="diary-main">
        {loading && (
          <div className="skeleton">
            <div className="skeleton-line w-80" />
            <div className="skeleton-line w-60" />
            <div className="skeleton-line w-100" />
          </div>
        )}

        {!loading && logs.length === 0 && !error && (
          <p className="empty-state">No food logged for this day.</p>
        )}

        {!loading &&
          mealSlotLogs.map(({ slot, items }) => (
            <section key={slot} className="meal-slot">
              <div className="meal-slot-header">
                <span className="meal-slot-name">{slot}</span>
                <span className="meal-slot-calories">
                  {Math.round(slotCalories(slot))} kcal
                </span>
                <button
                  className="meal-add-btn"
                  onClick={() =>
                    navigate("/search", {
                      state: { mealSlot: slot },
                    })
                  }
                  title={`Add to ${slot}`}
                >
                  +
                </button>
              </div>
              {items.length === 0 && (
                <p className="meal-slot-empty">No items</p>
              )}
              {items.map((log) => (
                <button
                  key={log.id}
                  className="log-row"
                  onClick={() => navigate(`/logs/${log.id}`)}
                >
                  <span className="log-row-name">
                    {foodNames[log.item.id] ?? "Loading..."}
                  </span>
                  <span className="log-row-qty">
                    {log.quantity.amount} {log.quantity.unit}
                  </span>
                  <span className="log-row-cal">
                    {Math.round(getCalories(log.nutrients))} kcal
                  </span>
                </button>
              ))}
            </section>
          ))}

        {!loading && otherLogs.length > 0 && (
          <section className="meal-slot">
            <div className="meal-slot-header">
              <span className="meal-slot-name">Other</span>
              <span className="meal-slot-calories">
                {Math.round(slotCalories(""))} kcal
              </span>
            </div>
            {otherLogs.map((log) => (
              <button
                key={log.id}
                className="log-row"
                onClick={() => navigate(`/logs/${log.id}`)}
              >
                <span className="log-row-name">
                  {foodNames[log.item.id] ?? "Loading..."}
                </span>
                <span className="log-row-qty">
                  {log.quantity.amount} {log.quantity.unit}
                </span>
                <span className="log-row-cal">
                  {Math.round(getCalories(log.nutrients))} kcal
                </span>
              </button>
            ))}
          </section>
        )}
      </main>
    </div>
  );
}
