import { useState, useEffect, useCallback } from "react";
import { useNavigate } from "react-router-dom";
import { listMeals } from "../api/meals";
import type { MealResponse } from "../api/meals";
import { Button } from "@/components/ui/button";
import { Card } from "@/components/ui/card";

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
          <div className="header-left">
            <button
            className="btn-back"
            onClick={() => navigate("/home")}
            aria-label="Back to Diary"
          >
            <span aria-hidden="true">‹</span>
          </button>
            <h1>Meals</h1>
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
            onClick={() => navigate("/home")}
            aria-label="Back to Diary"
          >
            <span aria-hidden="true">‹</span>
          </button>
            <h1>Meals</h1>
          </div>
        </header>
        <p className="error">{error}</p>
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
          <h1>Meals</h1>
        </div>
        <Button onClick={() => navigate("/meals/new")}>
          Create Meal
        </Button>
      </header>

      {meals.length === 0 && (
        <p className="empty-state">
          No meals yet. Create a meal to log common combinations faster.
        </p>
      )}

      <div className="search-results">
        {meals.map((meal) => (
          <Card
            key={meal.id}
            className="flex items-center w-full min-h-16 p-3.5 cursor-pointer hover:bg-muted/50"
            onClick={() => navigate(`/meals/${meal.id}`)}
          >
            <div className="flex flex-col gap-0.5 min-w-0">
              <span className="font-bold truncate">{meal.name}</span>
              <span className="text-muted-foreground text-sm">
                {meal.components.length} component
                {meal.components.length !== 1 ? "s" : ""}
                {meal.notes ? ` — ${meal.notes}` : ""}
              </span>
            </div>
          </Card>
        ))}
      </div>
    </div>
  );
}
