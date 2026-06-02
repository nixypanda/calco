import { useState, useEffect } from "react";
import { useParams, useNavigate } from "react-router-dom";
import { getLog, updateLog, deleteLog } from "../api/logs";
import { getFoodDetail, listUnits } from "../api/foods";
import { getMeal } from "../api/meals";
import type { LogResponse } from "../api/logs";
import type { ProductDetail, UnitItem } from "../api/foods";
import { Skeleton, Container, Stack } from "@mantine/core";
import { ErrorBanner } from "@/components/ErrorBanner";
import { PageHeader } from "@/components/PageHeader";
import { EmptyState } from "@/components/EmptyState";
import { FoodLogEntry } from "@/components/FoodLogEntry";

export function FoodLogDetail() {
  const { id } = useParams<{ id: string }>();
  const navigate = useNavigate();
  const [log, setLog] = useState<LogResponse | null>(null);
  const [food, setFood] = useState<ProductDetail | null>(null);
  const [itemName, setItemName] = useState("");
  const [units, setUnits] = useState<UnitItem[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState("");

  useEffect(() => {
    if (!id) return;
    let cancelled = false;
    setLoading(true);
    setError("");
    Promise.all([getLog(id), listUnits()])
      .then(async ([logRes, unitData]) => {
        if (cancelled) return;
        setLog(logRes);
        setUnits(unitData.items);
        if (logRes.item.type === "product") {
          try {
            const foodData = await getFoodDetail(logRes.item.id);
            if (!cancelled) {
              setFood(foodData);
              setItemName(foodData.name);
            }
          } catch {
            if (!cancelled) setItemName("Unknown food");
          }
        } else if (logRes.item.type === "meal") {
          try {
            const meal = await getMeal(logRes.item.id);
            if (!cancelled) setItemName(meal.name);
          } catch {
            if (!cancelled) setItemName("Unknown meal");
          }
        } else {
          setItemName("Unknown item");
        }
      })
      .catch((err: unknown) => {
        if (cancelled) return;
        setError(err instanceof Error ? err.message : "Failed to load log");
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
          title="Edit Log"
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

  if (error && !log) {
    return (
      <Container p="md">
        <PageHeader
          title="Edit Log"
          onBack={goHome}
          backLabel="Back to Diary"
        />
        <ErrorBanner message={error} />
      </Container>
    );
  }

  if (!log || !id) {
    return (
      <Container p="md">
        <PageHeader
          title="Edit Log"
          onBack={goHome}
          backLabel="Back to Diary"
        />
        <EmptyState>Log not found.</EmptyState>
      </Container>
    );
  }

  return (
    <FoodLogEntry
      title="Edit Log"
      itemName={itemName || "Loading..."}
      food={food}
      snapshot={{
        amount: log.quantity.amount,
        unit: log.quantity.unit,
        nutrients: log.nutrients,
      }}
      units={units}
      initial={{
        amount: log.quantity.amount,
        unit: log.quantity.unit,
        slot: log.meal_slot ?? "__none__",
        notes: log.notes ?? "",
      }}
      loggedAt={log.logged_at}
      brand={food?.brand}
      categories={food?.categories ?? []}
      servingSizeG={food?.serving_size_g}
      customFoodEditPath={
        food && food.source === "USER"
          ? `/foods/custom/${food.id}/edit`
          : undefined
      }
      submitLabel="Save"
      submittingLabel="Saving..."
      onSubmit={async (v) => {
        const updated = await updateLog(id, {
          quantity: { amount: v.amount, unit: v.unit },
          meal_slot: v.slot === "__none__" ? null : v.slot,
          notes: v.notes || null,
        });
        setLog(updated);
      }}
      onDelete={async () => {
        await deleteLog(id);
        navigate("/home", { replace: true });
      }}
      onBack={goHome}
      backLabel="Back to Diary"
    />
  );
}
