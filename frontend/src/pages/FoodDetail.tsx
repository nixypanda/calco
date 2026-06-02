import { Container, Skeleton, Stack } from "@mantine/core";
import { useEffect, useState } from "react";
import { useLocation, useNavigate, useParams } from "react-router-dom";
import { EmptyState } from "@/components/EmptyState";
import { ErrorBanner } from "@/components/ErrorBanner";
import { FoodLogEntry } from "@/components/FoodLogEntry";
import { PageHeader } from "@/components/PageHeader";
import { localISOString } from "@/lib/time";
import type { ProductDetail, UnitItem } from "../api/foods";
import { getFoodDetail, listUnits } from "../api/foods";
import { createLog } from "../api/logs";

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
      <Container p="md">
        <PageHeader
          title="Log Food"
          onBack={goHome}
          backLabel="Back to Diary"
        />
        <Stack gap="sm">
          <Skeleton height={16} width="80%" />
          <Skeleton height={16} width="60%" />
          <Skeleton height={16} width="100%" />
        </Stack>
      </Container>
    );
  }

  if (error && !food) {
    return (
      <Container p="md">
        <PageHeader
          title="Log Food"
          onBack={goHome}
          backLabel="Back to Diary"
        />
        <ErrorBanner message={error} />
      </Container>
    );
  }

  if (!food || !id) {
    return (
      <Container p="md">
        <PageHeader
          title="Log Food"
          onBack={goHome}
          backLabel="Back to Diary"
        />
        <EmptyState>Food not found.</EmptyState>
      </Container>
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
      categories={food.categories}
      servingSizeG={food.serving_size_g}
      customFoodEditPath={
        food.source === "USER" ? `/foods/custom/${food.id}/edit` : undefined
      }
      submitLabel="Log Food"
      submittingLabel="Logging..."
      onSubmit={async (v) => {
        await createLog({
          logged_at: localISOString(),
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
