import { useState, useEffect, useCallback } from "react";
import { useNavigate, useParams } from "react-router-dom";
import { getMeal, deleteMeal, getMealNutrients } from "../api/meals";
import { getFoodDetail } from "../api/foods";
import { createLog } from "../api/logs";
import type { MealResponse, MealNutritionResponse } from "../api/meals";

export function MealDetail() {
  const { id } = useParams<{ id: string }>();
  const navigate = useNavigate();

  const [meal, setMeal] = useState<MealResponse | null>(null);
  const [productNames, setProductNames] = useState<Record<string, string>>({});
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState("");

  const [logAmount, setLogAmount] = useState("100");
  const [logUnit] = useState("g");
  const [nutrients, setNutrients] = useState<MealNutritionResponse | null>(
    null,
  );
  const [nutrientsLoading, setNutrientsLoading] = useState(false);
  const [nutrientsError, setNutrientsError] = useState("");

  const [deleting, setDeleting] = useState(false);
  const [showConfirm, setShowConfirm] = useState(false);

  const [logging, setLogging] = useState(false);
  const [logError, setLogError] = useState("");

  const fetchMeal = useCallback(async () => {
    if (!id) return;
    setLoading(true);
    setError("");
    try {
      const mealData = await getMeal(id);
      if (!mealData) {
        setMeal(null);
        setLoading(false);
        return;
      }
      setMeal(mealData);

      const productIds = [
        ...new Set(
          mealData.components
            .filter((c) => c.item.type === "product")
            .map((c) => c.item.id),
        ),
      ];
      if (productIds.length > 0) {
        const details = await Promise.all(
          productIds.map((pid) => getFoodDetail(pid).catch(() => null)),
        );
        const nameMap: Record<string, string> = {};
        for (const d of details) {
          if (d) nameMap[d.id] = d.name;
        }
        setProductNames(nameMap);
      }
    } catch (err: unknown) {
      setError(err instanceof Error ? err.message : "Failed to load meal");
    } finally {
      setLoading(false);
    }
  }, [id]);

  useEffect(() => {
    fetchMeal();
  }, [fetchMeal]);

  const handleCalculate = useCallback(async () => {
    if (!id) return;
    setNutrientsLoading(true);
    setNutrientsError("");
    try {
      const result = await getMealNutrients(id, logAmount, logUnit);
      setNutrients(result);
    } catch (err: unknown) {
      setNutrientsError(
        err instanceof Error ? err.message : "Failed to calculate nutrients",
      );
    } finally {
      setNutrientsLoading(false);
    }
  }, [id, logAmount, logUnit]);

  const handleLog = useCallback(async () => {
    if (!id) return;
    setLogging(true);
    setLogError("");
    try {
      await createLog({
        logged_at: new Date().toISOString(),
        meal_slot: undefined,
        notes: undefined,
        item: { type: "meal", id },
        quantity: { amount: logAmount, unit: logUnit },
      });
      navigate("/home");
    } catch (err: unknown) {
      setLogError(
        err instanceof Error ? err.message : "Failed to log meal",
      );
    } finally {
      setLogging(false);
    }
  }, [id, logAmount, logUnit, navigate]);

  const handleDelete = useCallback(async () => {
    if (!id) return;
    setDeleting(true);
    try {
      await deleteMeal(id);
      navigate("/meals");
    } catch {
      setDeleting(false);
      setShowConfirm(false);
    }
  }, [id, navigate]);

  if (loading) {
    return (
      <div className="catalog-page">
        <header>
          <div className="header-left">
            <button
              className="btn-back"
              onClick={() => navigate("/meals")}
              aria-label="Back to Meals"
            >
              <span aria-hidden="true">‹</span>
            </button>
            <h1>Meal</h1>
          </div>
        </header>
        <div className="skeleton">
          <div className="skeleton-line w-80" />
          <div className="skeleton-line w-60" />
          <div className="skeleton-line w-100" />
        </div>
      </div>
    );
  }

  if (error) {
    return (
      <div className="catalog-page">
        <header>
          <div className="header-left">
            <button
              className="btn-back"
              onClick={() => navigate("/meals")}
              aria-label="Back to Meals"
            >
              <span aria-hidden="true">‹</span>
            </button>
            <h1>Meal</h1>
          </div>
        </header>
        <p className="error">{error}</p>
      </div>
    );
  }

  if (!meal) {
    return (
      <div className="catalog-page">
        <header>
          <div className="header-left">
            <button
              className="btn-back"
              onClick={() => navigate("/meals")}
              aria-label="Back to Meals"
            >
              <span aria-hidden="true">‹</span>
            </button>
            <h1>Meal</h1>
          </div>
        </header>
        <p className="empty-state">Meal not found.</p>
      </div>
    );
  }

  return (
    <div className="catalog-page">
      <header>
        <div className="header-left">
          <button
            className="btn-back"
            onClick={() => navigate("/meals")}
            aria-label="Back to Meals"
          >
            <span aria-hidden="true">‹</span>
          </button>
          <h1>{meal.name}</h1>
        </div>
        <div className="manage-actions">
          <button
            className="btn-secondary"
            onClick={() => navigate(`/meals/${id}/edit`)}
          >
            Edit
          </button>
          <button className="btn-danger" onClick={() => setShowConfirm(true)}>
            Delete
          </button>
        </div>
      </header>

      {meal.notes && (
        <p className="meta-item" style={{ marginBottom: "1rem" }}>
          {meal.notes}
        </p>
      )}

      <div className="detail-section">
        <h2>Components</h2>
        <div className="serving-list">
          {meal.components.map((comp) => (
            <div key={comp.id} className="serving-item">
              <span className="serving-label">
                {productNames[comp.item.id] ?? "Loading..."}
              </span>
              <span className="serving-amount">
                {comp.quantity.amount} {comp.quantity.unit}
              </span>
            </div>
          ))}
        </div>
      </div>

      <div className="detail-section">
        <h2>Log this meal</h2>
        <div className="log-food-form">
          <div className="amount-unit-row">
            <input
              className="amount-input"
              type="number"
              value={logAmount}
              onChange={(e) => setLogAmount(e.target.value)}
              placeholder="Amount"
            />
            <select className="unit-select" value={logUnit} disabled>
              <option value="g">g</option>
            </select>
            <button
              className="btn-primary"
              onClick={handleCalculate}
              disabled={nutrientsLoading}
            >
              {nutrientsLoading ? "..." : "Calculate"}
            </button>
          </div>
          {nutrientsError && <p className="error">{nutrientsError}</p>}
          {nutrients && (
            <>
              <table className="nutrient-table">
                <thead>
                  <tr>
                    <th>Nutrient</th>
                    <th className="amount-col">Amount</th>
                    <th className="unit-col">Unit</th>
                  </tr>
                </thead>
                <tbody>
                  {nutrients.nutrients.map((n) => (
                    <tr key={n.code}>
                      <td>{n.code}</td>
                      <td className="amount-col">{n.amount}</td>
                      <td className="unit-col">{n.unit}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
              <button
                className="btn-primary"
                onClick={handleLog}
                disabled={logging}
              >
                {logging ? "Logging..." : "Log Meal"}
              </button>
              {logError && <p className="error">{logError}</p>}
            </>
          )}
        </div>
      </div>

      {showConfirm && (
        <div className="detail-section">
          <p
            style={{ marginBottom: "0.5rem", color: "#dc2626", fontSize: "0.875rem" }}
          >
            Delete this meal?
          </p>
          <div className="manage-actions">
            <button
              className="btn-danger"
              onClick={handleDelete}
              disabled={deleting}
            >
              {deleting ? "Deleting..." : "Confirm Delete"}
            </button>
            <button
              className="btn-secondary"
              onClick={() => setShowConfirm(false)}
            >
              Cancel
            </button>
          </div>
        </div>
      )}
    </div>
  );
}
