import { useState, useEffect } from "react";
import { useParams, useNavigate, useLocation } from "react-router-dom";
import { getFoodDetail, listUnits } from "../api/foods";
import { createLog } from "../api/logs";
import type { ProductDetail, UnitItem } from "../api/foods";
import { Skeleton } from "@/components/ui/skeleton";
import { ErrorBanner } from "@/components/ErrorBanner";
import { PageHeader } from "@/components/PageHeader";
import { EmptyState } from "@/components/EmptyState";
import { FoodLogEntry } from "@/components/FoodLogEntry";

export function FoodDetail() {
  const { id } = useParams<{ id: string }>();
  const navigate = useNavigate();
  const location = useLocation();
  const [food, setFood] = useState<ProductDetail | null>(null);
  const [units, setUnits] = useState<UnitItem[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState("");
  const initialSlot =
    (location.state as { mealSlot?: string } | null)?.mealSlot ?? "__none__";

  useEffect(() => {
    if (!id) return;
    let cancelled = false;
    setLoading(true);
    setError("");
    Promise.all([getFoodDetail(id), listUnits()])
      .then(([foodData, unitData]) => {
        if (cancelled) return;
        setFood(foodData);
        setUnits(unitData.items);
      })
      .catch((err: unknown) => {
        if (cancelled) return;
        setError(err instanceof Error ? err.message : "Failed to load food");
      })
      .finally(() => {
        if (!cancelled) setLoading(false);
      });

    return () => {
      cancelled = true;
    };
  }, [id]);

  const goHome = () => navigate("/home");

  if (loading) {
    return (
      <div className="page">
        <PageHeader title="Log Food" onBack={goHome} backLabel="Back to Diary" />
        <div className="flex flex-col gap-3">
          <Skeleton className="h-4 w-4/5" />
          <Skeleton className="h-4 w-3/5" />
          <Skeleton className="h-4 w-full" />
        </div>
      </div>
    );
  }

  if (error && !food) {
    return (
      <div className="page">
        <PageHeader title="Log Food" onBack={goHome} backLabel="Back to Diary" />
        <ErrorBanner message={error} />
      </div>
    );
  }

  if (!food || !id) {
    return (
      <div className="page">
        <PageHeader title="Log Food" onBack={goHome} backLabel="Back to Diary" />
        <EmptyState>Food not found.</EmptyState>
      </div>
    );
  }

  return (
    <FoodLogEntry
      title="Log Food"
      itemName={food.name}
      food={food}
      units={units}
      initial={{
        amount: food.default_quantity ?? "1",
        unit: food.default_unit ?? "g",
        slot: initialSlot,
        notes: "",
      }}
      brand={food.brand}
      category={food.category}
      servingSizeG={food.serving_size_g}
      customFoodEditPath={
        food.source === "USER" ? `/foods/custom/${food.id}/edit` : undefined
      }
      submitLabel="Log Food"
      submittingLabel="Logging..."
      onSubmit={async (v) => {
        await createLog({
          logged_at: new Date().toISOString(),
          meal_slot: v.slot === "__none__" ? undefined : v.slot,
          item: { type: "product", id },
          quantity: { amount: v.amount, unit: v.unit },
          notes: v.notes || null,
        });
        navigate("/home");
      }}
      onBack={goHome}
      backLabel="Back to Diary"
    />
  );
}
