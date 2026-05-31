import { useState, useEffect, useCallback, useRef, type SubmitEvent } from "react";
import { useNavigate, useParams } from "react-router-dom";
import { createMeal, updateMeal, getMeal } from "../api/meals";
import { searchFoods } from "../api/foods";
import type { SearchResult } from "../api/foods";
import { Button } from "@/components/ui/button";
import { Skeleton } from "@/components/ui/skeleton";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";
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
  width = "w-20",
}: {
  value: string;
  onChange: (v: string) => void;
  width?: string;
}) {
  return (
    <Select value={value} onValueChange={onChange}>
      <SelectTrigger className={`${width} flex-none`}>
        <SelectValue />
      </SelectTrigger>
      <SelectContent>
        {UNITS.map((u) => (
          <SelectItem key={u} value={u}>{u}</SelectItem>
        ))}
      </SelectContent>
    </Select>
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
      <div className="page">
        <PageHeader title={title} onBack={goMeals} backLabel="Back to Meals" />
        <div className="flex flex-col gap-3">
          <Skeleton className="h-4 w-4/5" />
          <Skeleton className="h-4 w-3/5" />
          <Skeleton className="h-4 w-full" />
        </div>
      </div>
    );
  }

  return (
    <div className="page">
      <PageHeader title={title} onBack={goMeals} backLabel="Back to Meals" />

      {error && <ErrorBanner message={error} />}

      <form className="flex flex-col gap-3.5" onSubmit={handleSubmit}>
        <div className="flex flex-col gap-1.5">
          <Label htmlFor="mf-name">Name</Label>
          <Input
            id="mf-name"
            type="text"
            value={name}
            onChange={(e) => setName(e.target.value)}
            placeholder="Meal name"
          />
        </div>

        <div className="flex flex-col gap-1.5">
          <Label htmlFor="mf-notes">Notes</Label>
          <Input
            id="mf-notes"
            type="text"
            value={notes}
            onChange={(e) => setNotes(e.target.value)}
            placeholder="Optional notes"
          />
        </div>

        <section className="mb-5">
          <h2>Total Quantity (optional)</h2>
          <div className="flex gap-2.5">
            <Input
              type="number"
              value={totalQty}
              onChange={(e) => setTotalQty(e.target.value)}
              placeholder="Amount"
              className="flex-1"
            />
            <UnitSelect value={totalUnit} onChange={setTotalUnit} width="w-32" />
          </div>
        </section>

        <section className="mb-5">
          <div className="flex items-center justify-between gap-3 mb-3.5">
            <h2 className="mb-0">Components</h2>
            <Button type="button" variant="outline" size="sm" onClick={addComponent}>
              + Add Component
            </Button>
          </div>

          {components.map((comp, idx) => (
            <div key={idx} className="flex gap-2.5 items-center mb-2.5 flex-wrap">
              <div className="flex-[2] min-w-44 relative">
                <SearchQueryInput
                  value={comp.searchQuery}
                  onChange={(value) => handleSearchChange(value, idx)}
                  placeholder="Search product..."
                />
                {comp.searchResults.length > 0 && (
                  <div className="absolute top-full left-0 right-0 z-10 max-h-64 overflow-y-auto rounded-lg border border-border bg-card shadow-lg">
                    {comp.searchResults.map((r) => (
                      <FoodSearchResultRow
                        key={r.id}
                        item={r}
                        onSelect={() => selectProduct(r, idx)}
                      />
                    ))}
                  </div>
                )}
              </div>
              <Input
                type="number"
                value={comp.quantity}
                onChange={(e) => updateRow(idx, { quantity: e.target.value })}
                placeholder="Qty"
                className="w-20 flex-none"
              />
              <UnitSelect value={comp.unit} onChange={(v) => updateRow(idx, { unit: v })} />
              {components.length > 1 && (
                <Button
                  type="button"
                  variant="ghost"
                  size="icon"
                  className="text-destructive"
                  onClick={() => removeComponent(idx)}
                >
                  ×
                </Button>
              )}
            </div>
          ))}
        </section>

        <Button type="submit" disabled={submitting} className="self-start">
          {submitting ? "Saving..." : isEdit ? "Update Meal" : "Create Meal"}
        </Button>
      </form>
    </div>
  );
}
