import { useState, useEffect, useCallback, useRef, type SubmitEvent } from "react";
import { useNavigate, useParams } from "react-router-dom";
import { createMeal, updateMeal, getMeal } from "../api/meals";
import { searchFoods, getFoodDetail } from "../api/foods";
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
  rowId: string;
  productId: string;
  productName: string;
  quantity: string;
  unit: string;
  searchQuery: string;
  searchResults: SearchResult[];
  searching: boolean;
}

const UNITS = ["g", "kg", "ml", "cup", "tbsp", "tsp", "piece", "packet", "serving"];

let rowIdCounter = 0;
function nextRowId(): string {
  rowIdCounter += 1;
  return `row-${rowIdCounter}`;
}

function createEmptyRow(): ComponentRow {
  return {
    rowId: nextRowId(),
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

  const searchTimers = useRef<Map<string, ReturnType<typeof setTimeout>>>(new Map());

  useEffect(() => {
    if (!id) return;
    let cancelled = false;
    setFetching(true);
    setError("");
    (async () => {
      try {
        const meal = await getMeal(id);
        if (cancelled) return;
        setName(meal.name);
        setNotes(meal.notes ?? "");
        if (meal.total_quantity) {
          setTotalQty(meal.total_quantity.amount);
          setTotalUnit(meal.total_quantity.unit);
        }
        const productIds = [
          ...new Set(
            meal.components
              .filter((c) => c.item.type === "product")
              .map((c) => c.item.id),
          ),
        ];
        const nameMap: Record<string, string> = {};
        if (productIds.length > 0) {
          const details = await Promise.all(
            productIds.map((pid) =>
              Promise.resolve()
                .then(() => getFoodDetail(pid))
                .then((d) => ({ id: d?.id ?? pid, name: d?.name ?? "" }))
                .catch(() => ({ id: pid, name: "" })),
            ),
          );
          if (cancelled) return;
          for (const d of details) nameMap[d.id] = d.name;
        }
        setComponents(
          meal.components.map((c) => {
            const productName = nameMap[c.item.id] ?? "";
            return {
              rowId: nextRowId(),
              productId: c.item.id,
              productName,
              quantity: c.quantity.amount,
              unit: c.quantity.unit,
              searchQuery: productName,
              searchResults: [],
              searching: false,
            };
          }),
        );
      } catch (err: unknown) {
        if (cancelled) return;
        setError(err instanceof Error ? err.message : "Failed to load meal");
      } finally {
        if (!cancelled) setFetching(false);
      }
    })();
    return () => {
      cancelled = true;
    };
  }, [id]);

  useEffect(() => {
    const timers = searchTimers.current;
    const aborts = searchAborts.current;
    return () => {
      for (const t of timers.values()) clearTimeout(t);
      timers.clear();
      for (const a of aborts.values()) a.abort();
      aborts.clear();
    };
  }, []);

  const searchAborts = useRef<Map<string, AbortController>>(new Map());

  const doSearch = useCallback(async (query: string, rowId: string) => {
    if (query.length < 2) {
      setComponents((prev) =>
        prev.map((r) => (r.rowId === rowId ? { ...r, searchResults: [], searching: false } : r)),
      );
      return;
    }
    const prevAbort = searchAborts.current.get(rowId);
    if (prevAbort) prevAbort.abort();
    const controller = new AbortController();
    searchAborts.current.set(rowId, controller);
    setComponents((prev) =>
      prev.map((r) => (r.rowId === rowId ? { ...r, searching: true } : r)),
    );
    try {
      const res = await searchFoods(query, { signal: controller.signal });
      if (controller.signal.aborted) return;
      setComponents((prev) =>
        prev.map((r) =>
          r.rowId === rowId ? { ...r, searchResults: res.items, searching: false } : r,
        ),
      );
    } catch (err) {
      if (controller.signal.aborted) return;
      if (err instanceof DOMException && err.name === "AbortError") return;
      setComponents((prev) =>
        prev.map((r) => (r.rowId === rowId ? { ...r, searching: false } : r)),
      );
    }
  }, []);

  const handleSearchChange = (value: string, rowId: string) => {
    setComponents((prev) =>
      prev.map((r) => (r.rowId === rowId ? { ...r, searchQuery: value } : r)),
    );
    const existing = searchTimers.current.get(rowId);
    if (existing) clearTimeout(existing);
    const timer = setTimeout(() => doSearch(value, rowId), 300);
    searchTimers.current.set(rowId, timer);
  };

  const selectProduct = (result: SearchResult, rowId: string) => {
    setComponents((prev) =>
      prev.map((r) =>
        r.rowId === rowId
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

  const removeComponent = (rowId: string) => {
    const timer = searchTimers.current.get(rowId);
    if (timer) clearTimeout(timer);
    searchTimers.current.delete(rowId);
    const abort = searchAborts.current.get(rowId);
    if (abort) abort.abort();
    searchAborts.current.delete(rowId);
    setComponents((prev) => prev.filter((r) => r.rowId !== rowId));
  };

  const updateRow = (rowId: string, patch: Partial<ComponentRow>) =>
    setComponents((prev) => prev.map((r) => (r.rowId === rowId ? { ...r, ...patch } : r)));

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

            {components.map((comp) => (
              <Group key={comp.rowId} gap="xs" align="center" wrap="wrap">
                <Box pos="relative" miw={176} style={{ flex: 2 }}>
                  <SearchQueryInput
                    value={comp.searchQuery}
                    onChange={(value) => handleSearchChange(value, comp.rowId)}
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
                          onSelect={() => selectProduct(r, comp.rowId)}
                        />
                      ))}
                    </Paper>
                  )}
                </Box>
                <TextInput
                  type="number"
                  value={comp.quantity}
                  onChange={(e) => updateRow(comp.rowId, { quantity: e.target.value })}
                  placeholder="Qty"
                  w={80}
                />
                <UnitSelect value={comp.unit} onChange={(v) => updateRow(comp.rowId, { unit: v })} />
                {components.length > 1 && (
                  <ActionIcon
                    variant="subtle"
                    color="red"
                    onClick={() => removeComponent(comp.rowId)}
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
