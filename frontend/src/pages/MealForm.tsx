import { useState, useEffect, useCallback, useRef, type SubmitEvent } from "react";
import { useNavigate, useParams } from "react-router-dom";
import { createMeal, updateMeal, getMeal } from "../api/meals";
import { searchFoods } from "../api/foods";
import type { SearchResult } from "../api/foods";
import {
  ActionIcon,
  Button,
  Skeleton,
  TextInput,
  NativeSelect,
  Container,
  Group,
  Stack,
  Title,
  Paper,
  Box,
} from "@mantine/core";
import { ErrorBanner } from "@/components/ErrorBanner";
import { PageHeader } from "@/components/PageHeader";
import { SearchQueryInput } from "@/components/SearchQueryInput";
import { FoodSearchResultRow } from "@/components/FoodSearchResultRow";

interface ComponentRow {
  productId: string;
  productName: string;
  quantity: string;
  unit: string;
  searchQuery: string;
  searchResults: SearchResult[];
  searching: boolean;
}

const UNITS = ["g", "kg", "ml", "cup", "tbsp", "tsp", "piece", "packet", "serving"];

function createEmptyRow(): ComponentRow {
  return {
    productId: "",
    productName: "",
    quantity: "100",
    unit: "g",
    searchQuery: "",
    searchResults: [],
    searching: false,
  };
}

function UnitSelect({
  value,
  onChange,
  width = 80,
}: {
  value: string;
  onChange: (v: string) => void;
  width?: number;
}) {
  return (
    <NativeSelect
      value={value}
      onChange={(e) => onChange(e.target.value)}
      data={UNITS.map((u) => ({ value: u, label: u }))}
      w={width}
    />
  );
}

export function MealForm() {
  const { id } = useParams<{ id: string }>();
  const navigate = useNavigate();
  const isEdit = Boolean(id);

  const [name, setName] = useState("");
  const [notes, setNotes] = useState("");
  const [totalQty, setTotalQty] = useState("");
  const [totalUnit, setTotalUnit] = useState("g");
  const [components, setComponents] = useState<ComponentRow[]>([createEmptyRow()]);
  const [submitting, setSubmitting] = useState(false);
  const [fetching, setFetching] = useState(isEdit);
  const [error, setError] = useState("");

  const searchTimers = useRef<Map<number, ReturnType<typeof setTimeout>>>(new Map());

  useEffect(() => {
    if (!id) return;
    let cancelled = false;
    setFetching(true);
    setError("");
    getMeal(id)
      .then((meal) => {
        if (cancelled) return;
        setName(meal.name);
        setNotes(meal.notes ?? "");
        if (meal.total_quantity) {
          setTotalQty(meal.total_quantity.amount);
          setTotalUnit(meal.total_quantity.unit);
        }
        setComponents(
          meal.components.map((c) => ({
            productId: c.item.id,
            productName: "",
            quantity: c.quantity.amount,
            unit: c.quantity.unit,
            searchQuery: "",
            searchResults: [],
            searching: false,
          })),
        );
      })
      .catch((err: unknown) => {
        if (cancelled) return;
        setError(err instanceof Error ? err.message : "Failed to load meal");
      })
      .finally(() => {
        if (!cancelled) setFetching(false);
      });
    return () => {
      cancelled = true;
    };
  }, [id]);

  useEffect(() => {
    return () => {
      for (const t of searchTimers.current.values()) clearTimeout(t);
      searchTimers.current.clear();
    };
  }, []);

  const doSearch = useCallback(async (query: string, idx: number) => {
    if (query.length < 2) {
      setComponents((prev) =>
        prev.map((r, i) => (i === idx ? { ...r, searchResults: [], searching: false } : r)),
      );
      return;
    }
    setComponents((prev) => prev.map((r, i) => (i === idx ? { ...r, searching: true } : r)));
    try {
      const res = await searchFoods(query);
      setComponents((prev) =>
        prev.map((r, i) =>
          i === idx ? { ...r, searchResults: res.items, searching: false } : r,
        ),
      );
    } catch {
      setComponents((prev) =>
        prev.map((r, i) => (i === idx ? { ...r, searching: false } : r)),
      );
    }
  }, []);

  const handleSearchChange = (value: string, idx: number) => {
    setComponents((prev) =>
      prev.map((r, i) => (i === idx ? { ...r, searchQuery: value } : r)),
    );
    const existing = searchTimers.current.get(idx);
    if (existing) clearTimeout(existing);
    const timer = setTimeout(() => doSearch(value, idx), 300);
    searchTimers.current.set(idx, timer);
  };

  const selectProduct = (result: SearchResult, idx: number) => {
    setComponents((prev) =>
      prev.map((r, i) =>
        i === idx
          ? {
              ...r,
              productId: result.id,
              productName: result.name,
              searchQuery: result.name,
              searchResults: [],
              searching: false,
            }
          : r,
      ),
    );
  };

  const addComponent = () => setComponents((prev) => [...prev, createEmptyRow()]);

  const removeComponent = (idx: number) =>
    setComponents((prev) => prev.filter((_, i) => i !== idx));

  const updateRow = (idx: number, patch: Partial<ComponentRow>) =>
    setComponents((prev) => prev.map((r, i) => (i === idx ? { ...r, ...patch } : r)));

  const handleSubmit = async (e: SubmitEvent<HTMLFormElement>) => {
    e.preventDefault();
    setSubmitting(true);
    setError("");

    if (!name.trim()) {
      setError("Name is required");
      setSubmitting(false);
      return;
    }

    const validComponents = components.filter((c) => c.productId);
    if (validComponents.length === 0) {
      setError("At least one component with a selected product is required");
      setSubmitting(false);
      return;
    }

    const payload = {
      name: name.trim(),
      notes: notes.trim() || null,
      total_quantity: totalQty.trim()
        ? { amount: totalQty.trim(), unit: totalUnit }
        : null,
      components: validComponents.map((c) => ({
        item: { type: "product", id: c.productId },
        quantity: { amount: c.quantity || "100", unit: c.unit || "g" },
      })),
    };

    try {
      if (isEdit && id) {
        const updated = await updateMeal(id, payload);
        navigate(`/meals/${updated.id}`);
      } else {
        const created = await createMeal(payload);
        navigate(`/meals/${created.id}`);
      }
    } catch (err: unknown) {
      setError(err instanceof Error ? err.message : "Failed to save meal");
    } finally {
      setSubmitting(false);
    }
  };

  const title = isEdit ? "Edit Meal" : "Create Meal";
  const goMeals = () => navigate("/meals");

  if (fetching) {
    return (
      <Container p="md">
        <PageHeader title={title} onBack={goMeals} backLabel="Back to Meals" />
        <Stack gap="sm">
          <Skeleton height={16} width="80%" />
          <Skeleton height={16} width="60%" />
          <Skeleton height={16} width="100%" />
        </Stack>
      </Container>
    );
  }

  return (
    <Container p="md">
      <PageHeader title={title} onBack={goMeals} backLabel="Back to Meals" />

      {error && <ErrorBanner message={error} />}

      <form onSubmit={handleSubmit}>
        <Stack gap="sm">
          <TextInput
            id="mf-name"
            label="Name"
            type="text"
            value={name}
            onChange={(e) => setName(e.target.value)}
            placeholder="Meal name"
          />

          <TextInput
            id="mf-notes"
            label="Notes"
            type="text"
            value={notes}
            onChange={(e) => setNotes(e.target.value)}
            placeholder="Optional notes"
          />

          <Stack gap="sm">
            <Title order={2}>Total Quantity (optional)</Title>
            <Group gap="xs">
              <TextInput
                type="number"
                value={totalQty}
                onChange={(e) => setTotalQty(e.target.value)}
                placeholder="Amount"
                style={{ flex: 1 }}
              />
              <UnitSelect value={totalUnit} onChange={setTotalUnit} width={128} />
            </Group>
          </Stack>

          <Stack gap="sm">
            <Group justify="space-between">
              <Title order={2}>Components</Title>
              <Button type="button" variant="outline" size="sm" onClick={addComponent}>
                + Add Component
              </Button>
            </Group>

            {components.map((comp, idx) => (
              <Group key={idx} gap="xs" align="center" wrap="wrap">
                <Box pos="relative" miw={176} style={{ flex: 2 }}>
                  <SearchQueryInput
                    value={comp.searchQuery}
                    onChange={(value) => handleSearchChange(value, idx)}
                    placeholder="Search product..."
                  />
                  {comp.searchResults.length > 0 && (
                    <Paper
                      pos="absolute"
                      top="100%"
                      left={0}
                      right={0}
                      mah={256}
                      style={{ zIndex: 10, overflowY: "auto" }}
                      withBorder
                      shadow="md"
                    >
                      {comp.searchResults.map((r) => (
                        <FoodSearchResultRow
                          key={r.id}
                          item={r}
                          onSelect={() => selectProduct(r, idx)}
                        />
                      ))}
                    </Paper>
                  )}
                </Box>
                <TextInput
                  type="number"
                  value={comp.quantity}
                  onChange={(e) => updateRow(idx, { quantity: e.target.value })}
                  placeholder="Qty"
                  w={80}
                />
                <UnitSelect value={comp.unit} onChange={(v) => updateRow(idx, { unit: v })} />
                {components.length > 1 && (
                  <ActionIcon
                    variant="subtle"
                    color="red"
                    onClick={() => removeComponent(idx)}
                  >
                    ×
                  </ActionIcon>
                )}
              </Group>
            ))}
          </Stack>

          <Button type="submit" disabled={submitting} style={{ alignSelf: "flex-start" }}>
            {submitting ? "Saving..." : isEdit ? "Update Meal" : "Create Meal"}
          </Button>
        </Stack>
      </form>
    </Container>
  );
}
