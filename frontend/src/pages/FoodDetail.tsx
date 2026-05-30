import { useState, useEffect } from "react";
import { useParams, useNavigate, useLocation } from "react-router-dom";
import { getFoodDetail, deleteCustomFood, listUnits } from "../api/foods";
import { createLog } from "../api/logs";
import type { ProductDetail, UnitItem } from "../api/foods";

const MEAL_SLOTS = ["Breakfast", "Lunch", "Dinner", "Snack"] as const;

export function FoodDetail() {
  const { id } = useParams<{ id: string }>();
  const navigate = useNavigate();
  const location = useLocation();
  const [food, setFood] = useState<ProductDetail | null>(null);
  const [units, setUnits] = useState<UnitItem[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState("");
  const [deleting, setDeleting] = useState(false);
  const [logAmount, setLogAmount] = useState("1");
  const [logUnit, setLogUnit] = useState("g");
  const [logSlot, setLogSlot] = useState(
    (location.state as { mealSlot?: string } | null)?.mealSlot ?? "",
  );
  const [logging, setLogging] = useState(false);

  useEffect(() => {
    if (!id) return;
    setLoading(true);
    setError("");
    Promise.all([getFoodDetail(id), listUnits()])
      .then(([foodData, unitData]) => {
        setFood(foodData);
        setUnits(unitData.items);
        setLogUnit(foodData.default_unit ?? "g");
      })
      .catch((err: unknown) => {
        setError(err instanceof Error ? err.message : "Failed to load food");
      })
      .finally(() => setLoading(false));
  }, [id]);

  const handleLog = async () => {
    if (!id || !food) return;
    setLogging(true);
    setError("");
    try {
      await createLog({
        logged_at: new Date().toISOString(),
        meal_slot: logSlot ? logSlot.toLowerCase() : undefined,
        item: { type: "product", id },
        quantity: { amount: logAmount, unit: logUnit },
      });
      navigate("/home");
    } catch (err: unknown) {
      setError(err instanceof Error ? err.message : "Failed to log food");
    } finally {
      setLogging(false);
    }
  };

  const handleDelete = async () => {
    if (!id || !food) return;
    if (!window.confirm(`Delete "${food.name}"? This cannot be undone.`)) return;
    setDeleting(true);
    try {
      await deleteCustomFood(id);
      navigate("/search", { replace: true });
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
          <h1>Food Detail</h1>
          <button onClick={() => navigate(-1)}>Back</button>
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

  if (error && !food) {
    return (
      <div className="catalog-page">
        <header>
          <h1>Food Detail</h1>
          <button onClick={() => navigate(-1)}>Back</button>
        </header>
        <main>
          <p className="error">{error}</p>
        </main>
      </div>
    );
  }

  if (!food) {
    return (
      <div className="catalog-page">
        <header>
          <h1>Food Detail</h1>
          <button onClick={() => navigate(-1)}>Back</button>
        </header>
        <main>
          <p className="empty-state">Food not found.</p>
        </main>
      </div>
    );
  }

  const isCustom = food.source === "USER";

  return (
    <div className="catalog-page">
      <header>
        <h1>{food.name}</h1>
        <button onClick={() => navigate(-1)}>Back</button>
      </header>

      <main>
        <div className="food-detail-header">
          <div className="food-detail-meta">
            {food.brand && <span className="meta-item">{food.brand}</span>}
            {food.category && (
              <span className="category-chip">{food.category}</span>
            )}
            {isCustom && <span className="source-chip">Custom</span>}
          </div>
          {food.serving_size_g && (
            <p className="serving-size">
              Serving size: {food.serving_size_g}g
            </p>
          )}
        </div>

        <section className="detail-section">
          <h2>Nutrition per 100g</h2>
          <table className="nutrient-table">
            <thead>
              <tr>
                <th>Nutrient</th>
                <th className="amount-col">Amount</th>
                <th className="unit-col">Unit</th>
              </tr>
            </thead>
            <tbody>
              {food.nutrients.map((n) => (
                <tr key={n.code}>
                  <td>{n.code.replace(/_/g, " ").toLowerCase()}</td>
                  <td className="amount-col">{n.amount_per_100g}</td>
                  <td className="unit-col">{n.unit || "-"}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </section>

        {food.servings.length > 0 && (
          <section className="detail-section">
            <h2>Servings</h2>
            <div className="serving-list">
              {food.servings.map((s, i) => (
                <div key={i} className="serving-item">
                  <span className="serving-label">{s.label}</span>
                  <span className="serving-amount">
                    {s.quantity} {s.unit} ({s.grams}g)
                  </span>
                </div>
              ))}
            </div>
          </section>
        )}

        <section className="detail-section">
          <h2>Log Food</h2>
          <div className="log-food-form">
            <div className="log-field">
              <label>Meal</label>
              <select
                className="meal-slot-select"
                value={logSlot}
                onChange={(e) => setLogSlot(e.target.value)}
              >
                <option value="">No meal slot</option>
                {MEAL_SLOTS.map((s) => (
                  <option key={s} value={s}>
                    {s}
                  </option>
                ))}
              </select>
            </div>
            <div className="log-field">
              <label>Amount</label>
              <div className="amount-unit-row">
                <input
                  type="number"
                  className="amount-input"
                  value={logAmount}
                  onChange={(e) => setLogAmount(e.target.value)}
                  min={0}
                  step="any"
                  placeholder="Amount"
                />
                <select
                  className="unit-select"
                  value={logUnit}
                  onChange={(e) => setLogUnit(e.target.value)}
                >
                  {units.map((u) => (
                    <option key={u.code} value={u.code}>
                      {u.name} ({u.code})
                    </option>
                  ))}
                </select>
              </div>
            </div>
            <button
              className="btn-primary"
              onClick={handleLog}
              disabled={logging}
            >
              {logging ? "Logging..." : "Log Food"}
            </button>
            {error && <p className="error">{error}</p>}
          </div>
        </section>

        {isCustom && (
          <section className="detail-section">
            <h2>Manage Food</h2>
            <div className="manage-actions">
              <button
                className="btn-secondary"
                onClick={() => navigate(`/foods/custom/${id}/edit`)}
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
          </section>
        )}
      </main>
    </div>
  );
}
