import { useState, useEffect, type SubmitEvent } from "react";
import { useNavigate } from "react-router-dom";
import { createCustomFood, listNutrients, listUnits } from "../api/foods";
import type { NutrientItem, UnitItem } from "../api/foods";
import {
  ActionIcon,
  Button,
  TextInput,
  NativeSelect,
  Container,
  Group,
  Stack,
  Title,
} from "@mantine/core";
import { ErrorBanner } from "@/components/ErrorBanner";
import { PageHeader } from "@/components/PageHeader";
import { parseCategoriesInput } from "@/lib/categories";

interface NutrientRow {
  code: string;
  amount_per_100g: string;
}

interface ServingRow {
  label: string;
  quantity: string;
  unit: string;
  grams: string;
}

export function CustomFoodCreate() {
  const navigate = useNavigate();
  const [nutrients, setNutrients] = useState<NutrientItem[]>([]);
  const [units, setUnits] = useState<UnitItem[]>([]);
  const [name, setName] = useState("");
  const [brand, setBrand] = useState("");
  const [category, setCategory] = useState("");
  const [servingSizeG, setServingSizeG] = useState("");
  const [defaultQty, setDefaultQty] = useState("");
  const [defaultUnit, setDefaultUnit] = useState("g");
  const [nutrientRows, setNutrientRows] = useState<NutrientRow[]>([
    { code: "", amount_per_100g: "" },
  ]);
  const [servingRows, setServingRows] = useState<ServingRow[]>([]);
  const [submitting, setSubmitting] = useState(false);
  const [error, setError] = useState("");

  useEffect(() => {
    let cancelled = false;
    Promise.allSettled([listNutrients(), listUnits()]).then((results) => {
      if (cancelled) return;
      const [nRes, uRes] = results;
      const failures: string[] = [];
      if (nRes.status === "fulfilled") setNutrients(nRes.value.items);
      else failures.push("nutrients");
      if (uRes.status === "fulfilled") setUnits(uRes.value.items);
      else failures.push("units");
      if (failures.length > 0) setError(`Failed to load ${failures.join(" and ")}`);
    });
    return () => {
      cancelled = true;
    };
  }, []);

  const addNutrientRow = () =>
    setNutrientRows([...nutrientRows, { code: "", amount_per_100g: "" }]);

  const removeNutrientRow = (i: number) => {
    if (nutrientRows.length <= 1) return;
    setNutrientRows(nutrientRows.filter((_, idx) => idx !== i));
  };

  const updateNutrientRow = (i: number, field: keyof NutrientRow, value: string) => {
    const rows = [...nutrientRows];
    rows[i] = { ...rows[i], [field]: value };
    setNutrientRows(rows);
  };

  const addServingRow = () =>
    setServingRows([...servingRows, { label: "", quantity: "", unit: "g", grams: "" }]);

  const removeServingRow = (i: number) =>
    setServingRows(servingRows.filter((_, idx) => idx !== i));

  const updateServingRow = (i: number, field: keyof ServingRow, value: string) => {
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

    const validNutrients = nutrientRows.filter((r) => r.code && r.amount_per_100g);
    const validServings = servingRows.filter((r) => r.label && r.quantity && r.grams);

    setSubmitting(true);
    try {
      const res = await createCustomFood({
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
      });
      navigate(`/foods/${res.id}`, { replace: true });
    } catch (err: unknown) {
      setError(err instanceof Error ? err.message : "Failed to create food");
    } finally {
      setSubmitting(false);
    }
  };

  return (
    <Container p="md">
      <PageHeader
        title="Create Custom Food"
        onBack={() => navigate("/home")}
        backLabel="Back to Diary"
      />

      {error && <ErrorBanner message={error} />}

      <form onSubmit={handleSubmit}>
        <Stack gap="lg">
          <Stack gap="sm">
            <Title order={2}>Basic Info</Title>
            <TextInput
              id="cf-name"
              label="Name *"
              value={name}
              onChange={(e) => setName(e.target.value)}
              required
              autoFocus
              disabled={submitting}
            />
            <TextInput
              id="cf-brand"
              label="Brand"
              value={brand}
              onChange={(e) => setBrand(e.target.value)}
              disabled={submitting}
            />
            <TextInput
              id="cf-category"
              label="Category"
              value={category}
              onChange={(e) => setCategory(e.target.value)}
              disabled={submitting}
            />
          </Stack>

          <Stack gap="sm">
            <Title order={2}>Portion Info</Title>
            <TextInput
              id="cf-serving"
              label="Serving Size (g)"
              type="number"
              value={servingSizeG}
              onChange={(e) => setServingSizeG(e.target.value)}
              min={0}
              step="any"
              disabled={submitting}
            />
            <TextInput
              id="cf-defqty"
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
              data={units.map((u) => ({ value: u.code, label: `${u.name} (${u.code})` }))}
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
                  onChange={(e) => updateNutrientRow(i, "amount_per_100g", e.target.value)}
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
                  onChange={(e) => updateServingRow(i, "quantity", e.target.value)}
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

          <Button type="submit" disabled={submitting} style={{ alignSelf: "flex-start" }}>
            {submitting ? "Creating..." : "Create Food"}
          </Button>
        </Stack>
      </form>
    </Container>
  );
}
