import { useState, useEffect, useCallback } from "react";
import { useNavigate } from "react-router-dom";
import { listMeals } from "../api/meals";
import type { MealResponse } from "../api/meals";

export function Meals() {
  const navigate = useNavigate();
  const [meals, setMeals] = useState<MealResponse[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState("");

  const fetchMeals = useCallback(async () => {
    setLoading(true);
    setError("");
    try {
      const res = await listMeals();
      setMeals(res.items);
    } catch (err: unknown) {
      setError(err instanceof Error ? err.message : "Failed to load meals");
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    fetchMeals();
  }, [fetchMeals]);

  if (loading) {
    return (
      <div className="catalog-page">
        <header>
          <h1>Meals</h1>
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
          <h1>Meals</h1>
        </header>
        <p className="error">{error}</p>
      </div>
    );
  }

  return (
    <div className="catalog-page">
      <header>
        <h1>Meals</h1>
        <button className="btn-primary" onClick={() => navigate("/meals/new")}>
          Create Meal
        </button>
      </header>

      {meals.length === 0 && (
        <p className="empty-state">
          No meals yet. Create a meal to log common combinations faster.
        </p>
      )}

      <div className="search-results">
        {meals.map((meal) => (
          <button
            key={meal.id}
            className="search-result"
            onClick={() => navigate(`/meals/${meal.id}`)}
          >
            <div className="search-result-main">
              <span className="search-result-name">{meal.name}</span>
              <span className="search-result-brand">
                {meal.components.length} component
                {meal.components.length !== 1 ? "s" : ""}
                {meal.notes ? ` — ${meal.notes}` : ""}
              </span>
            </div>
          </button>
        ))}
      </div>
    </div>
  );
}
