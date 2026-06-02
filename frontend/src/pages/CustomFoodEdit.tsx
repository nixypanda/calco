import { useState, useEffect } from "react";
import { useParams, useNavigate } from "react-router-dom";
import {
  getFoodDetail,
  updateCustomFood,
  listNutrients,
  listUnits,
} from "../api/foods";
import type { NutrientItem, UnitItem } from "../api/foods";
import { Container, Skeleton, Stack } from "@mantine/core";
import { ErrorBanner } from "@/components/ErrorBanner";
import { PageHeader } from "@/components/PageHeader";
import {
  CustomFoodForm,
  type CustomFoodFormValues,
} from "@/components/CustomFoodForm";
import { formatCategoriesInput } from "@/lib/nutrition";

export function CustomFoodEdit() {
  const { id } = useParams<{ id: string }>();
  const navigate = useNavigate();
  const [nutrients, setNutrients] = useState<NutrientItem[]>([]);
  const [units, setUnits] = useState<UnitItem[]>([]);
  const [initialValues, setInitialValues] =
    useState<CustomFoodFormValues | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState("");

  useEffect(() => {
    if (!id) {
      setError("Missing food id in URL");
      setLoading(false);
      return;
    }
    let cancelled = false;
    Promise.all([getFoodDetail(id), listNutrients(), listUnits()])
      .then(([food, n, u]) => {
        if (cancelled) return;
        setInitialValues({
          name: food.name,
          brand: food.brand ?? "",
          category: formatCategoriesInput(food.categories),
          servingSizeG: food.serving_size_g ?? "",
          defaultQty: food.default_quantity ?? "",
          defaultUnit: food.default_unit ?? "g",
          nutrientRows:
            food.nutrients.length > 0
              ? food.nutrients.map((nr) => ({
                  code: nr.code,
                  amount_per_100g: nr.amount_per_100g,
                }))
              : [{ code: "", amount_per_100g: "" }],
          servingRows: food.servings.map((s) => ({
            label: s.label,
            quantity: s.quantity,
            unit: s.unit,
            grams: s.grams,
          })),
        });
        setNutrients(n.items);
        setUnits(u.items);
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
          title="Edit Custom Food"
          onBack={goHome}
          backLabel="Back to Diary"
        />
        <Stack gap="sm">
          <Skeleton height={16} width="80%" />
          <Skeleton height={16} width="60%" />
        </Stack>
      </Container>
    );
  }

  return (
    <Container p="md">
      <PageHeader
        title="Edit Custom Food"
        onBack={goHome}
        backLabel="Back to Diary"
      />

      {error && <ErrorBanner message={error} />}

      {initialValues && id && (
        <CustomFoodForm
          idPrefix="cfe"
          submitLabel="Save Changes"
          submitPendingLabel="Saving..."
          failureMessage="Failed to update food"
          initialValues={initialValues}
          nutrients={nutrients}
          units={units}
          onSubmit={async (payload) => {
            const res = await updateCustomFood(id, payload);
            navigate(`/foods/${res.id}`, { replace: true });
          }}
        />
      )}
    </Container>
  );
}
