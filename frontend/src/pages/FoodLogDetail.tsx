import { useState, useEffect } from "react";
import { useParams, useNavigate } from "react-router-dom";
import { getLog, updateLog, deleteLog } from "../api/logs";
import { getFoodDetail } from "../api/foods";
import type { LogResponse } from "../api/logs";

const MEAL_SLOTS = [
  { value: "breakfast", label: "Breakfast" },
  { value: "lunch", label: "Lunch" },
  { value: "dinner", label: "Dinner" },
  { value: "snack", label: "Snack" },
] as const;

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

export function FoodLogDetail() {
  const { id } = useParams<{ id: string }>();
  const navigate = useNavigate();
  const [log, setLog] = useState<LogResponse | null>(null);
  const [foodName, setFoodName] = useState("");
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState("");
  const [editing, setEditing] = useState(false);
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
          <h1>Food Log</h1>
          <button onClick={() => navigate("/home")}>Back to Diary</button>
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
          <h1>Food Log</h1>
          <button onClick={() => navigate("/home")}>Back to Diary</button>
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
          <h1>Food Log</h1>
          <button onClick={() => navigate("/home")}>Back to Diary</button>
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
        <h1>Food Log</h1>
        <button onClick={() => navigate("/home")}>Back to Diary</button>
      </header>

      <main>
        {error && <p className="error">{error}</p>}

        <div className="food-detail-header">
          <h2 className="log-detail-name">{foodName || "Loading..."}</h2>
          <p className="log-detail-time">{formatTimestamp(log.logged_at)}</p>
        </div>

        {!editing ? (
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
        ) : (
          <>
            <section className="detail-section">
              <h2>Edit Log</h2>
              <div className="log-edit-form">
                <label>
                  Meal Slot
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
                <label>
                  Amount
                  <input
                    type="number"
                    value={editQty}
                    onChange={(e) => setEditQty(e.target.value)}
                    min={0}
                    step="any"
                  />
                </label>
                <label>
                  Unit
                  <input
                    type="text"
                    value={editUnit}
                    onChange={(e) => setEditUnit(e.target.value)}
                  />
                </label>
                <label>
                  Notes
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
                    className="btn-secondary"
                    onClick={() => {
                      setEditing(false);
                      if (log) {
                        setEditQty(log.quantity.amount);
                        setEditUnit(log.quantity.unit);
                        setEditSlot(log.meal_slot ?? "");
                        setEditNotes(log.notes ?? "");
                      }
                    }}
                  >
                    Cancel
                  </button>
                </div>
              </div>
            </section>
          </>
        )}
      </main>
    </div>
  );
}
