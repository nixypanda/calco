import { useState, useEffect, useCallback } from "react";
import { useNavigate } from "react-router-dom";
import { listMeals } from "../api/meals";
import type { MealResponse } from "../api/meals";
import { Button } from "@/components/ui/button";
import { Skeleton } from "@/components/ui/skeleton";
import { Card } from "@/components/ui/card";
import { ErrorBanner } from "@/components/ErrorBanner";
import { plural } from "@/lib/plural";

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
      <div className="w-full max-w-[760px] mx-auto p-4 pt-[calc(1rem+env(safe-area-inset-top))] pb-[calc(1.5rem+env(safe-area-inset-bottom))]">
        <header className="flex items-center justify-between gap-4 mb-4">
          <div className="flex items-center gap-2.5 min-w-0">
            <button
            className="inline-flex items-center justify-center min-w-[44px] min-h-[44px] pr-2 bg-transparent border-0 rounded-xl text-muted-foreground cursor-pointer text-base font-bold hover:bg-accent"
            onClick={() => navigate("/home")}
            aria-label="Back to Diary"
          >
            <span className="text-[2rem] leading-[0.8]" aria-hidden="true">‹</span>
          </button>
            <h1 className="text-foreground text-[1.75rem] max-sm:text-[1.5rem] font-extrabold">Meals</h1>
          </div>
        </header>
        <div className="flex flex-col gap-3">
          <Skeleton className="h-4 w-4/5" />
          <Skeleton className="h-4 w-3/5" />
          <Skeleton className="h-4 w-full" />
        </div>
      </div>
    );
  }

  if (error) {
    return (
      <div className="w-full max-w-[760px] mx-auto p-4 pt-[calc(1rem+env(safe-area-inset-top))] pb-[calc(1.5rem+env(safe-area-inset-bottom))]">
        <header className="flex items-center justify-between gap-4 mb-4">
          <div className="flex items-center gap-2.5 min-w-0">
            <button
            className="inline-flex items-center justify-center min-w-[44px] min-h-[44px] pr-2 bg-transparent border-0 rounded-xl text-muted-foreground cursor-pointer text-base font-bold hover:bg-accent"
            onClick={() => navigate("/home")}
            aria-label="Back to Diary"
          >
            <span className="text-[2rem] leading-[0.8]" aria-hidden="true">‹</span>
          </button>
            <h1 className="text-foreground text-[1.75rem] max-sm:text-[1.5rem] font-extrabold">Meals</h1>
          </div>
        </header>
        <ErrorBanner message={error} />
      </div>
    );
  }

  return (
    <div className="w-full max-w-[760px] mx-auto p-4 pt-[calc(1rem+env(safe-area-inset-top))] pb-[calc(1.5rem+env(safe-area-inset-bottom))]">
      <header className="flex items-center justify-between gap-4 mb-4">
        <div className="flex items-center gap-2.5 min-w-0">
          <button
            className="inline-flex items-center justify-center min-w-[44px] min-h-[44px] pr-2 bg-transparent border-0 rounded-xl text-muted-foreground cursor-pointer text-base font-bold hover:bg-accent"
            onClick={() => navigate("/home")}
            aria-label="Back to Diary"
          >
            <span className="text-[2rem] leading-[0.8]" aria-hidden="true">‹</span>
          </button>
          <h1 className="text-foreground text-[1.75rem] max-sm:text-[1.5rem] font-extrabold">Meals</h1>
        </div>
        <Button onClick={() => navigate("/meals/new")}>
          Create Meal
        </Button>
      </header>

      {meals.length === 0 && (
        <p className="flex flex-col items-center justify-center gap-3.5 py-10 px-4 text-muted-foreground text-sm text-center">
          No meals yet. Create a meal to log common combinations faster.
        </p>
      )}

      <div className="flex flex-col gap-3">
        {meals.map((meal) => (
          <Card
            key={meal.id}
            className="flex items-center w-full min-h-16 p-3.5 cursor-pointer hover:bg-muted/50"
            onClick={() => navigate(`/meals/${meal.id}`)}
          >
            <div className="flex flex-col gap-0.5 min-w-0">
              <span className="font-bold truncate">{meal.name}</span>
              <span className="text-muted-foreground text-sm">
                {plural(meal.components.length, "component")}
                {meal.notes ? ` — ${meal.notes}` : ""}
              </span>
            </div>
          </Card>
        ))}
      </div>
    </div>
  );
}
