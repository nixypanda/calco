import { useState, useEffect, useCallback } from "react";
import { useNavigate } from "react-router-dom";
import { listMeals } from "../api/meals";
import type { MealResponse } from "../api/meals";
import { Button } from "@/components/ui/button";
import { Skeleton } from "@/components/ui/skeleton";
import { Card } from "@/components/ui/card";
import { ErrorBanner } from "@/components/ErrorBanner";
import { PageHeader } from "@/components/PageHeader";
import { EmptyState } from "@/components/EmptyState";
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

  const goHome = () => navigate("/home");

  if (loading) {
    return (
      <div className="page">
        <PageHeader title="Meals" onBack={goHome} backLabel="Back to Diary" />
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
      <div className="page">
        <PageHeader title="Meals" onBack={goHome} backLabel="Back to Diary" />
        <ErrorBanner message={error} />
      </div>
    );
  }

  return (
    <div className="page">
      <PageHeader title="Meals" onBack={goHome} backLabel="Back to Diary">
        <Button onClick={() => navigate("/meals/new")}>Create Meal</Button>
      </PageHeader>

      {meals.length === 0 && (
        <EmptyState>No meals yet. Create a meal to log common combinations faster.</EmptyState>
      )}

      <div className="flex flex-col gap-3">
        {meals.map((meal) => (
          <Card
            key={meal.id}
            className="flex p-4 cursor-pointer hover:bg-muted/50"
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
