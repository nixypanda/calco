import { useState, useEffect, useCallback, useRef } from "react";
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

interface ComponentRow {
  productId: string;
  productName: string;
  quantity: string;
  unit: string;
  searchQuery: string;
  searchResults: SearchResult[];
  searching: boolean;
}

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

export function MealForm() {
  const { id } = useParams<{ id: string }>();
  const navigate = useNavigate();
  const isEdit = Boolean(id);

  const [name, setName] = useState("");
  const [notes, setNotes] = useState("");
  const [totalQty, setTotalQty] = useState("");
  const [totalUnit, setTotalUnit] = useState("g");
  const [components, setComponents] = useState<ComponentRow[]>([
    createEmptyRow(),
  ]);
  const [submitting, setSubmitting] = useState(false);
  const [fetching, setFetching] = useState(isEdit);
  const [error, setError] = useState("");

  const searchTimers = useRef<Map<number, ReturnType<typeof setTimeout>>>(
    new Map(),
  );

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
      for (const t of searchTimers.current.values()) {
        clearTimeout(t);
      }
      searchTimers.current.clear();
    };
  }, []);

  const doSearch = useCallback(async (query: string, idx: number) => {
    if (query.length < 2) {
      setComponents((prev) =>
        prev.map((r, i) =>
          i === idx ? { ...r, searchResults: [], searching: false } : r,
        ),
      );
      return;
    }
    setComponents((prev) =>
      prev.map((r, i) => (i === idx ? { ...r, searching: true } : r)),
    );
    try {
      const res = await searchFoods(query);
      setComponents((prev) =>
        prev.map((r, i) =>
          i === idx ? { ...r, searchResults: res.items, searching: false } : r,
        ),
      );
    } catch {
      setComponents((prev) =>
        prev.map((r, i) =>
          i === idx ? { ...r, searching: false } : r,
        ),
      );
    }
  }, []);

  const handleSearchChange = (value: string, idx: number) => {
    setComponents((prev) =>
      prev.map((r, i) =>
        i === idx ? { ...r, searchQuery: value } : r,
      ),
    );

    const existing = searchTimers.current.get(idx);
    if (existing) clearTimeout(existing);

    const timer = setTimeout(() => {
      doSearch(value, idx);
    }, 300);
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

  const addComponent = () => {
    setComponents((prev) => [...prev, createEmptyRow()]);
  };

  const removeComponent = (idx: number) => {
    setComponents((prev) => prev.filter((_, i) => i !== idx));
  };

  const handleSubmit = async (e: React.FormEvent) => {
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
      total_quantity:
        totalQty.trim()
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
      setError(
        err instanceof Error ? err.message : "Failed to save meal",
      );
    } finally {
      setSubmitting(false);
    }
  };

  if (fetching) {
    return (
      <div className="w-full max-w-[760px] mx-auto p-4 pt-[calc(1rem+env(safe-area-inset-top))] pb-[calc(1.5rem+env(safe-area-inset-bottom))]">
        <header className="flex items-center justify-between gap-4 mb-4">
          <div className="flex items-center gap-2.5 min-w-0">
            <button
              className="inline-flex items-center justify-center min-w-[44px] min-h-[44px] pr-2 bg-transparent border-0 rounded-xl text-muted-foreground cursor-pointer text-base font-bold hover:bg-accent"
              onClick={() => navigate("/meals")}
              aria-label="Back to Meals"
            >
              <span className="text-[2rem] leading-[0.8]" aria-hidden="true">‹</span>
            </button>
            <h1 className="text-foreground text-[1.75rem] max-sm:text-[1.5rem] font-extrabold">{isEdit ? "Edit Meal" : "Create Meal"}</h1>
          </div>
        </header>
        <div className="flex flex-col gap-3">
          <Skeleton className="h-4 w-4/5" />
          <Skeleton className="h-4 w-3/5" />
          <Skeleton className="h-4 w-full" />
        </div>
      </div>
    );
  }

  return (
    <div className="w-full max-w-[760px] mx-auto p-4 pt-[calc(1rem+env(safe-area-inset-top))] pb-[calc(1.5rem+env(safe-area-inset-bottom))]">
      <header className="flex items-center justify-between gap-4 mb-4">
        <div className="flex items-center gap-2.5 min-w-0">
          <button
            className="inline-flex items-center justify-center min-w-[44px] min-h-[44px] pr-2 bg-transparent border-0 rounded-xl text-muted-foreground cursor-pointer text-base font-bold hover:bg-accent"
            onClick={() => navigate("/meals")}
            aria-label="Back to Meals"
          >
            <span className="text-[2rem] leading-[0.8]" aria-hidden="true">‹</span>
          </button>
          <h1 className="text-foreground text-[1.75rem] max-sm:text-[1.5rem] font-extrabold">{isEdit ? "Edit Meal" : "Create Meal"}</h1>
        </div>
      </header>

      {error && <ErrorBanner message={error} />}

      <form className="flex flex-col gap-3.5" onSubmit={handleSubmit}>
        <div className="flex flex-col gap-1.5">
          <Label htmlFor="mf-name" className="text-xs font-bold text-muted-foreground">Name</Label>
          <Input
            id="mf-name"
            type="text"
            value={name}
            onChange={(e) => setName(e.target.value)}
            placeholder="Meal name"
          />
        </div>

        <div className="flex flex-col gap-1.5">
          <Label htmlFor="mf-notes" className="text-xs font-bold text-muted-foreground">Notes</Label>
          <Input
            id="mf-notes"
            type="text"
            value={notes}
            onChange={(e) => setNotes(e.target.value)}
            placeholder="Optional notes"
          />
        </div>

        <div className="mb-5">
          <h2>Total Quantity (optional)</h2>
          <div className="flex gap-2.5">
            <Input
              type="number"
              value={totalQty}
              onChange={(e) => setTotalQty(e.target.value)}
              placeholder="Amount"
              className="flex-1"
            />
            <Select value={totalUnit} onValueChange={setTotalUnit}>
              <SelectTrigger className="w-[132px] flex-none">
                <SelectValue />
              </SelectTrigger>
              <SelectContent>
                <SelectItem value="g">g</SelectItem>
                <SelectItem value="kg">kg</SelectItem>
                <SelectItem value="ml">ml</SelectItem>
                <SelectItem value="cup">cup</SelectItem>
                <SelectItem value="tbsp">tbsp</SelectItem>
                <SelectItem value="tsp">tsp</SelectItem>
                <SelectItem value="piece">piece</SelectItem>
                <SelectItem value="packet">packet</SelectItem>
                <SelectItem value="serving">serving</SelectItem>
              </SelectContent>
            </Select>
          </div>
        </div>

        <div className="mb-5">
          <div className="flex items-center justify-between gap-3 mb-3.5">
            <h2>Components</h2>
            <Button type="button" variant="outline" size="sm" onClick={addComponent}>
              + Add Component
            </Button>
          </div>

          {components.map((comp, idx) => (
            <div key={idx} className="flex gap-2.5 items-center mb-2.5 flex-wrap">
              <div className="flex-[2] min-w-[180px] relative">
                <Input
                  type="text"
                  value={comp.searchQuery}
                  onChange={(e) => handleSearchChange(e.target.value, idx)}
                  placeholder="Search product..."
                />
                {comp.searchResults.length > 0 && (
                  <div className="absolute top-full left-0 right-0 z-10 max-h-[220px] overflow-y-auto bg-card border border-border rounded-lg shadow-lg">
                    {comp.searchResults.map((r) => (
                      <button
                        key={r.id}
                        type="button"
                        className="block w-full text-left px-3.5 py-3 text-sm border-b border-border hover:bg-muted last:border-b-0"
                        onClick={() => selectProduct(r, idx)}
                      >
                        <strong>{r.name}</strong>
                        {r.brand && (
                          <span className="text-muted-foreground ml-1">— {r.brand}</span>
                        )}
                      </button>
                    ))}
                  </div>
                )}
              </div>
              <Input
                type="number"
                value={comp.quantity}
                onChange={(e) =>
                  setComponents((prev) =>
                    prev.map((r, i) =>
                      i === idx ? { ...r, quantity: e.target.value } : r,
                    ),
                  )
                }
                placeholder="Qty"
                className="w-[80px] flex-none"
              />
              <Select
                value={comp.unit}
                onValueChange={(value) =>
                  setComponents((prev) =>
                    prev.map((r, i) =>
                      i === idx ? { ...r, unit: value } : r,
                    ),
                  )
                }
              >
                <SelectTrigger className="w-[80px] flex-none">
                  <SelectValue />
                </SelectTrigger>
                <SelectContent>
                  <SelectItem value="g">g</SelectItem>
                  <SelectItem value="kg">kg</SelectItem>
                  <SelectItem value="ml">ml</SelectItem>
                  <SelectItem value="cup">cup</SelectItem>
                  <SelectItem value="tbsp">tbsp</SelectItem>
                  <SelectItem value="tsp">tsp</SelectItem>
                  <SelectItem value="piece">piece</SelectItem>
                  <SelectItem value="packet">packet</SelectItem>
                  <SelectItem value="serving">serving</SelectItem>
                </SelectContent>
              </Select>
              {components.length > 1 && (
                <Button
                  type="button"
                  variant="ghost"
                  className="text-destructive w-11 h-11 p-0"
                  onClick={() => removeComponent(idx)}
                >
                  ×
                </Button>
              )}
            </div>
          ))}
        </div>

        <Button type="submit" disabled={submitting} className="self-start">
          {submitting
            ? "Saving..."
            : isEdit
              ? "Update Meal"
              : "Create Meal"}
        </Button>
      </form>
    </div>
  );
}
