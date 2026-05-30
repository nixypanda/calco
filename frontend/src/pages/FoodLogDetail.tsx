import { useState, useEffect } from "react";
import { useParams, useNavigate, useLocation } from "react-router-dom";
import { getLog, updateLog, deleteLog } from "../api/logs";
import { getFoodDetail } from "../api/foods";
import type { LogResponse } from "../api/logs";

const MEAL_SLOTS = [
  { value: "breakfast", label: "Breakfast" },
  { value: "lunch", label: "Lunch" },
  { value: "dinner", label: "Dinner" },
  { value: "snack", label: "Snack" },
] as const;
const MACRO_COLORS = {
  protein: "#ff9f0a",
  carbs: "#34c759",
  fat: "#ffcc00",
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
  return isNaN(n) ? 0 : n;
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
    <div className="macro-breakdown log-macro-breakdown">
      <div className="macro-donut">
        <svg width={size} height={size} className="macro-donut-svg">
          <circle
            cx={size / 2}
            cy={size / 2}
            r={radius}
            fill="none"
            stroke="#e5e5e5"
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
        <div className="macro-donut-center">
          <span className="macro-donut-calories">
            {Math.round(macros.calories)}
          </span>
          <span className="macro-donut-unit">kcal</span>
        </div>
      </div>
      <div className="macro-stat-grid">
        <MacroStat
          name="Protein"
          grams={macros.protein}
          percent={macros.proteinPct}
          color={MACRO_COLORS.protein}
        />
        <MacroStat
          name="Carbs"
          grams={macros.carbs}
          percent={macros.carbsPct}
          color={MACRO_COLORS.carbs}
        />
        <MacroStat
          name="Fat"
          grams={macros.fat}
          percent={macros.fatPct}
          color={MACRO_COLORS.fat}
        />
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
    <div className="macro-stat" style={{ borderColor: color }}>
      <span className="macro-stat-percent" style={{ color }}>{Math.round(percent)}%</span>
      <span className="macro-stat-grams">{grams.toFixed(1)}g</span>
      <span className="macro-stat-name">{name}</span>
    </div>
  );
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
  const [editSlot, setEditSlot] = useState("");
  const [editNotes, setEditNotes] = useState("");

  useEffect(() => {
    if (!id) return;
    setLoading(true);
    setError("");
    getLog(id)
      .then(async (logRes) => {
        setLog(logRes);
        setEditQty(logRes.quantity.amount);
        setEditUnit(logRes.quantity.unit);
        setEditSlot(logRes.meal_slot ?? "");
        setEditNotes(logRes.notes ?? "");

        if (logRes.item.type === "product") {
          try {
            const detail = await getFoodDetail(logRes.item.id);
            setFoodName(detail.name);
          } catch {
            setFoodName("Unknown food");
          }
        } else {
          setFoodName("Unknown item");
        }
      })
      .catch((err: unknown) => {
        setError(err instanceof Error ? err.message : "Failed to load log");
      })
      .finally(() => setLoading(false));
  }, [id]);

  const handleSave = async () => {
    if (!id || !log) return;
    setSaving(true);
    setError("");
    try {
      const updated = await updateLog(id, {
        quantity: { amount: editQty, unit: editUnit },
        meal_slot: editSlot || null,
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

  if (loading) {
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
            <h1>Food Log</h1>
          </div>
        </header>
        <main>
          <div className="skeleton">
            <div className="skeleton-line w-80" />
            <div className="skeleton-line w-60" />
            <div className="skeleton-line w-100" />
          </div>
        </main>
      </div>
    );
  }

  if (error && !log) {
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
            <h1>Food Log</h1>
          </div>
        </header>
        <main>
          <p className="error">{error}</p>
        </main>
      </div>
    );
  }

  if (!log) {
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
            <h1>Food Log</h1>
          </div>
        </header>
        <main>
          <p className="empty-state">Log not found.</p>
        </main>
      </div>
    );
  }

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
          <h1>{editing ? "Edit Log" : "Food Log"}</h1>
        </div>
      </header>

      <main>
        {error && <p className="error">{error}</p>}

        <div className="food-detail-header">
          <h2 className="log-detail-name">{foodName || "Loading..."}</h2>
          <p className="log-detail-time">{formatTimestamp(log.logged_at)}</p>
        </div>

        {editing ? (
          <>
            <section className="detail-section">
              <div className="log-edit-form">
                <label className="log-edit-row">
                  <span>Meal Slot</span>
                  <select
                    value={editSlot}
                    onChange={(e) => setEditSlot(e.target.value)}
                  >
                    <option value="">None</option>
                    {MEAL_SLOTS.map((s) => (
                      <option key={s.value} value={s.value}>
                        {s.label}
                      </option>
                    ))}
                  </select>
                </label>
                <label className="log-edit-row">
                  <span>Amount</span>
                  <input
                    type="number"
                    value={editQty}
                    onChange={(e) => setEditQty(e.target.value)}
                    min={0}
                    step="any"
                  />
                </label>
                <label className="log-edit-row">
                  <span>Unit</span>
                  <input
                    type="text"
                    value={editUnit}
                    onChange={(e) => setEditUnit(e.target.value)}
                  />
                </label>
                <label className="log-edit-row">
                  <span>Notes</span>
                  <input
                    type="text"
                    value={editNotes}
                    onChange={(e) => setEditNotes(e.target.value)}
                    placeholder="Optional notes"
                  />
                </label>
                <div className="manage-actions">
                  <button
                    className="btn-primary"
                    onClick={handleSave}
                    disabled={saving}
                  >
                    {saving ? "Saving..." : "Save"}
                  </button>
                  <button
                    className="btn-danger"
                    onClick={handleDelete}
                    disabled={deleting}
                  >
                    {deleting ? "Deleting..." : "Delete"}
                  </button>
                </div>
              </div>
            </section>

            <section className="detail-section">
              <h2>Macro Breakdown</h2>
              <MacroDonut log={log} />
            </section>

            <section className="detail-section">
              <h2>Nutrients</h2>
              <table className="nutrient-table">
                <thead>
                  <tr>
                    <th>Nutrient</th>
                    <th className="amount-col">Amount</th>
                    <th className="unit-col">Unit</th>
                  </tr>
                </thead>
                <tbody>
                  {log.nutrients.map((n) => (
                    <tr key={n.code}>
                      <td>
                        {n.code.replace(/_/g, " ").toLowerCase()}
                      </td>
                      <td className="amount-col">
                        {parseFloat(n.amount).toFixed(1)}
                      </td>
                      <td className="unit-col">{n.unit || "-"}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </section>

          </>
        ) : (
          <>
            <section className="detail-section">
              <h2>Details</h2>
              <table className="nutrient-table">
                <tbody>
                  <tr>
                    <td>Meal Slot</td>
                    <td>{mealSlotLabel(log.meal_slot)}</td>
                  </tr>
                  <tr>
                    <td>Quantity</td>
                    <td>
                      {log.quantity.amount} {log.quantity.unit}
                    </td>
                  </tr>
                  <tr>
                    <td>Notes</td>
                    <td>{log.notes || "-"}</td>
                  </tr>
                </tbody>
              </table>
            </section>

            <section className="detail-section">
              <h2>Macro Breakdown</h2>
              <MacroDonut log={log} />
            </section>

            <section className="detail-section">
              <h2>Nutrients</h2>
              <table className="nutrient-table">
                <thead>
                  <tr>
                    <th>Nutrient</th>
                    <th className="amount-col">Amount</th>
                    <th className="unit-col">Unit</th>
                  </tr>
                </thead>
                <tbody>
                  {log.nutrients.map((n) => (
                    <tr key={n.code}>
                      <td>
                        {n.code.replace(/_/g, " ").toLowerCase()}
                      </td>
                      <td className="amount-col">
                        {parseFloat(n.amount).toFixed(1)}
                      </td>
                      <td className="unit-col">{n.unit || "-"}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </section>

            <div className="manage-actions">
              <button
                className="btn-primary"
                onClick={() => setEditing(true)}
              >
                Edit
              </button>
              <button
                className="btn-danger"
                onClick={handleDelete}
                disabled={deleting}
              >
                {deleting ? "Deleting..." : "Delete"}
              </button>
            </div>
          </>
        )}
      </main>
    </div>
  );
}
