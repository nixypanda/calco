import { useState, type SubmitEvent } from "react";
import {
  ActionIcon,
  Button,
  TextInput,
  NativeSelect,
  Group,
  Stack,
  Title,
} from "@mantine/core";
import { ErrorBanner } from "@/components/ErrorBanner";
import {
  parseCategoriesInput,
  type NutrientRow,
  type ServingRow,
} from "@/lib/nutrition";
import type { CreateFoodRequest, NutrientItem, UnitItem } from "@/api/foods";

export interface CustomFoodFormValues {
  name: string;
  brand: string;
  category: string;
  servingSizeG: string;
  defaultQty: string;
  defaultUnit: string;
  nutrientRows: NutrientRow[];
  servingRows: ServingRow[];
}

const EMPTY_VALUES: CustomFoodFormValues = {
  name: "",
  brand: "",
  category: "",
  servingSizeG: "",
  defaultQty: "",
  defaultUnit: "g",
  nutrientRows: [{ code: "", amount_per_100g: "" }],
  servingRows: [],
};

export interface CustomFoodFormProps {
  idPrefix: string;
  submitLabel: string;
  submitPendingLabel: string;
  failureMessage: string;
  initialValues?: CustomFoodFormValues;
  nutrients: NutrientItem[];
  units: UnitItem[];
  onSubmit: (payload: CreateFoodRequest) => Promise<void>;
}

export function CustomFoodForm({
  idPrefix,
  submitLabel,
  submitPendingLabel,
  failureMessage,
  initialValues,
  nutrients,
  units,
  onSubmit,
}: CustomFoodFormProps) {
  const seed = initialValues ?? EMPTY_VALUES;
  const [name, setName] = useState(seed.name);
  const [brand, setBrand] = useState(seed.brand);
  const [category, setCategory] = useState(seed.category);
  const [servingSizeG, setServingSizeG] = useState(seed.servingSizeG);
  const [defaultQty, setDefaultQty] = useState(seed.defaultQty);
  const [defaultUnit, setDefaultUnit] = useState(seed.defaultUnit);
  const [nutrientRows, setNutrientRows] = useState<NutrientRow[]>(
    seed.nutrientRows,
  );
  const [servingRows, setServingRows] = useState<ServingRow[]>(
    seed.servingRows,
  );
  const [submitting, setSubmitting] = useState(false);
  const [error, setError] = useState("");

  const addNutrientRow = () =>
    setNutrientRows([...nutrientRows, { code: "", amount_per_100g: "" }]);

  const removeNutrientRow = (i: number) => {
    if (nutrientRows.length <= 1) return;
    setNutrientRows(nutrientRows.filter((_, idx) => idx !== i));
  };

  const updateNutrientRow = (
    i: number,
    field: keyof NutrientRow,
    value: string,
  ) => {
    const rows = [...nutrientRows];
    rows[i] = { ...rows[i], [field]: value };
    setNutrientRows(rows);
  };

  const addServingRow = () =>
    setServingRows([
      ...servingRows,
      { label: "", quantity: "", unit: "g", grams: "" },
    ]);

  const removeServingRow = (i: number) =>
    setServingRows(servingRows.filter((_, idx) => idx !== i));

  const updateServingRow = (
    i: number,
    field: keyof ServingRow,
    value: string,
  ) => {
    const rows = [...servingRows];
    rows[i] = { ...rows[i], [field]: value };
    setServingRows(rows);
  };

  const handleSubmit = async (e: SubmitEvent<HTMLFormElement>) => {
    e.preventDefault();
    setError("");

    if (!name.trim()) {
      setError("Name is required");
      return;
    }

    const validNutrients = nutrientRows.filter(
      (r) => r.code && r.amount_per_100g,
    );
    const validServings = servingRows.filter(
      (r) => r.label && r.quantity && r.grams,
    );

    const payload: CreateFoodRequest = {
      name: name.trim(),
      brand: brand.trim() || null,
      categories: parseCategoriesInput(category),
      serving_size_g: servingSizeG || null,
      default_quantity: defaultQty || null,
      default_unit: defaultUnit || null,
      nutrients: validNutrients.map((r) => ({
        code: r.code,
        amount_per_100g: r.amount_per_100g,
      })),
      servings: validServings.map((r) => ({
        label: r.label,
        quantity: r.quantity,
        unit: r.unit,
        grams: r.grams,
      })),
    };

    setSubmitting(true);
    try {
      await onSubmit(payload);
    } catch (err: unknown) {
      setError(err instanceof Error ? err.message : failureMessage);
    } finally {
      setSubmitting(false);
    }
  };

  return (
    <>
      {error && <ErrorBanner message={error} />}

      <form onSubmit={handleSubmit}>
        <Stack gap="lg">
          <Stack gap="sm">
            <Title order={2}>Basic Info</Title>
            <TextInput
              id={`${idPrefix}-name`}
              label="Name *"
              value={name}
              onChange={(e) => setName(e.target.value)}
              required
              autoFocus
              disabled={submitting}
            />
            <TextInput
              id={`${idPrefix}-brand`}
              label="Brand"
              value={brand}
              onChange={(e) => setBrand(e.target.value)}
              disabled={submitting}
            />
            <TextInput
              id={`${idPrefix}-category`}
              label="Category"
              value={category}
              onChange={(e) => setCategory(e.target.value)}
              disabled={submitting}
            />
          </Stack>

          <Stack gap="sm">
            <Title order={2}>Portion Info</Title>
            <TextInput
              id={`${idPrefix}-serving`}
              label="Serving Size (g)"
              type="number"
              value={servingSizeG}
              onChange={(e) => setServingSizeG(e.target.value)}
              min={0}
              step="any"
              disabled={submitting}
            />
            <TextInput
              id={`${idPrefix}-defqty`}
              label="Default Quantity"
              type="number"
              value={defaultQty}
              onChange={(e) => setDefaultQty(e.target.value)}
              min={0}
              step="any"
              disabled={submitting}
            />
            <NativeSelect
              label="Default Unit"
              value={defaultUnit}
              onChange={(e) => setDefaultUnit(e.target.value)}
              disabled={submitting}
              data={units.map((u) => ({
                value: u.code,
                label: `${u.name} (${u.code})`,
              }))}
            />
          </Stack>

          <Stack gap="sm">
            <Group justify="space-between">
              <Title order={2}>Nutrients (per 100g)</Title>
              <Button
                type="button"
                variant="outline"
                size="sm"
                onClick={addNutrientRow}
                disabled={submitting}
              >
                + Add Nutrient
              </Button>
            </Group>
            {nutrientRows.map((row, i) => (
              <Group key={i} gap="xs" align="center">
                <NativeSelect
                  value={row.code}
                  onChange={(e) => updateNutrientRow(i, "code", e.target.value)}
                  disabled={submitting}
                  data={[
                    { value: "", label: "Select nutrient..." },
                    ...nutrients.map((n) => ({ value: n.code, label: n.name })),
                  ]}
                  style={{ flex: 1 }}
                />
                <TextInput
                  type="number"
                  placeholder="Amount per 100g"
                  value={row.amount_per_100g}
                  onChange={(e) =>
                    updateNutrientRow(i, "amount_per_100g", e.target.value)
                  }
                  min={0}
                  step="any"
                  disabled={submitting}
                  style={{ flex: 1 }}
                />
                <ActionIcon
                  variant="subtle"
                  color="red"
                  onClick={() => removeNutrientRow(i)}
                  disabled={nutrientRows.length <= 1 || submitting}
                >
                  ×
                </ActionIcon>
              </Group>
            ))}
          </Stack>

          <Stack gap="sm">
            <Group justify="space-between">
              <Title order={2}>Servings</Title>
              <Button
                type="button"
                variant="outline"
                size="sm"
                onClick={addServingRow}
                disabled={submitting}
              >
                + Add Serving
              </Button>
            </Group>
            {servingRows.map((row, i) => (
              <Group key={i} gap="xs" align="center" wrap="wrap">
                <TextInput
                  placeholder="Label (e.g. scoop)"
                  value={row.label}
                  onChange={(e) => updateServingRow(i, "label", e.target.value)}
                  disabled={submitting}
                  style={{ flex: 1 }}
                />
                <TextInput
                  type="number"
                  placeholder="Qty"
                  value={row.quantity}
                  onChange={(e) =>
                    updateServingRow(i, "quantity", e.target.value)
                  }
                  min={0}
                  step="any"
                  disabled={submitting}
                  style={{ flex: 1 }}
                />
                <NativeSelect
                  value={row.unit}
                  onChange={(e) => updateServingRow(i, "unit", e.target.value)}
                  disabled={submitting}
                  data={units.map((u) => ({ value: u.code, label: u.code }))}
                  w={96}
                />
                <TextInput
                  type="number"
                  placeholder="Grams"
                  value={row.grams}
                  onChange={(e) => updateServingRow(i, "grams", e.target.value)}
                  min={0}
                  step="any"
                  disabled={submitting}
                  style={{ flex: 1 }}
                />
                <ActionIcon
                  variant="subtle"
                  color="red"
                  onClick={() => removeServingRow(i)}
                  disabled={submitting}
                >
                  ×
                </ActionIcon>
              </Group>
            ))}
          </Stack>

          <Button
            type="submit"
            disabled={submitting}
            style={{ alignSelf: "flex-start" }}
          >
            {submitting ? submitPendingLabel : submitLabel}
          </Button>
        </Stack>
      </form>
    </>
  );
}
