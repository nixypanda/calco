import { useState, useEffect, useCallback } from "react";
import { useNavigate } from "react-router-dom";
import { getSummary } from "../api/logs";

const SUMMARY_CODES = "ENERGY_KCAL,PROTEIN_G,CARBS_G,FAT_G";
const MAX_DAYS = 90;

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

function getDaysInRange(from: Date, to: Date): Date[] {
  const days: Date[] = [];
  const current = new Date(from);
  current.setHours(0, 0, 0, 0);
  const end = new Date(to);
  end.setHours(0, 0, 0, 0);
  while (current <= end) {
    days.push(new Date(current));
    current.setDate(current.getDate() + 1);
  }
  return days;
}

interface DaySummary {
  date: string;
  calories: number;
  protein: number;
  carbs: number;
  fat: number;
}

export function History() {
  const navigate = useNavigate();
  const today = new Date();
  const sevenDaysAgo = new Date(today);
  sevenDaysAgo.setDate(sevenDaysAgo.getDate() - 6);

  const [fromDate, setFromDate] = useState(sevenDaysAgo);
  const [toDate, setToDate] = useState(today);
  const [days, setDays] = useState<DaySummary[]>([]);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState("");

  const fetchHistory = useCallback(async () => {
    setLoading(true);
    setError("");
    try {
      const allDays = getDaysInRange(fromDate, toDate);
      const results = await Promise.all(
        allDays.map(async (d) => {
          const ds = formatDate(d);
          try {
            const res = await getSummary(ds, ds, SUMMARY_CODES);
            const getVal = (code: string) => {
              const e = res.totals.find((t) => t.code === code);
              return e ? parseAmount(e.amount) : 0;
            };
            return {
              date: ds,
              calories: getVal("ENERGY_KCAL"),
              protein: getVal("PROTEIN_G"),
              carbs: getVal("CARBS_G"),
              fat: getVal("FAT_G"),
            };
          } catch {
            return { date: ds, calories: 0, protein: 0, carbs: 0, fat: 0 };
          }
        }),
      );
      setDays(results);
    } catch (err: unknown) {
      setError(err instanceof Error ? err.message : "Failed to load history");
    } finally {
      setLoading(false);
    }
  }, [fromDate, toDate]);

  useEffect(() => {
    fetchHistory();
  }, [fetchHistory]);

  const daysInRange = getDaysInRange(fromDate, toDate).length;

  return (
    <div className="catalog-page">
      <header>
        <div className="header-left">
          <button
            className="btn-back"
            onClick={() => navigate("/home")}
            aria-label="Back to Diary"
          >
            <span aria-hidden="true">‹</span>
          </button>
          <h1>History</h1>
        </div>
      </header>

      <main>
        <div className="history-range">
          <label>
            From
            <input
              type="date"
              value={formatDate(fromDate)}
              onChange={(e) => {
                const d = new Date(e.target.value + "T00:00:00");
                if (!isNaN(d.getTime())) setFromDate(d);
              }}
            />
          </label>
          <label>
            To
            <input
              type="date"
              value={formatDate(toDate)}
              onChange={(e) => {
                const d = new Date(e.target.value + "T00:00:00");
                if (!isNaN(d.getTime())) setToDate(d);
              }}
              max={formatDate(new Date())}
            />
          </label>
        </div>

        {daysInRange > MAX_DAYS && (
          <p className="error">
            Range too large (max {MAX_DAYS} days, selected {daysInRange})
          </p>
        )}

        {error && <p className="error">{error}</p>}

        {loading && (
          <div className="skeleton">
            <div className="skeleton-line w-100" />
            <div className="skeleton-line w-100" />
            <div className="skeleton-line w-100" />
          </div>
        )}

        {!loading && days.length === 0 && !error && (
          <p className="empty-state">No data for the selected range.</p>
        )}

        {!loading && days.length > 0 && (
          <div className="history-table-wrapper">
            <table className="history-table">
              <thead>
                <tr>
                  <th>Date</th>
                  <th className="num-col">Calories</th>
                  <th className="num-col">Protein</th>
                  <th className="num-col">Carbs</th>
                  <th className="num-col">Fat</th>
                </tr>
              </thead>
              <tbody>
                {days.map((d) => (
                  <tr
                    key={d.date}
                    className="history-row"
                    onClick={() => navigate(`/home?date=${d.date}`)}
                  >
                    <td>{displayDate(new Date(d.date + "T00:00:00"))}</td>
                    <td className="num-col">{Math.round(d.calories)}</td>
                    <td className="num-col">
                      {d.protein.toFixed(1)}
                    </td>
                    <td className="num-col">{d.carbs.toFixed(1)}</td>
                    <td className="num-col">{d.fat.toFixed(1)}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
      </main>
    </div>
  );
}
