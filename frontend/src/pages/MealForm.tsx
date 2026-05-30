import { useState, useEffect, useCallback, useRef } from "react";
import { useNavigate, useParams } from "react-router-dom";
import { createMeal, updateMeal, getMeal } from "../api/meals";
import { searchFoods } from "../api/foods";
import type { SearchResult } from "../api/foods";

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

  const fetchMeal = useCallback(async () => {
    if (!id) return;
    setFetching(true);
    setError("");
    try {
      const meal = await getMeal(id);
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
    } catch (err: unknown) {
      setError(
        err instanceof Error ? err.message : "Failed to load meal",
      );
    } finally {
      setFetching(false);
    }
  }, [id]);

  useEffect(() => {
    if (isEdit) fetchMeal();
  }, [isEdit, fetchMeal]);

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
      <div className="catalog-page">
        <header>
          <div className="header-left">
            <button
              className="btn-back"
              onClick={() => navigate("/meals")}
              aria-label="Back to Meals"
            >
              <span aria-hidden="true">‹</span>
            </button>
            <h1>{isEdit ? "Edit Meal" : "Create Meal"}</h1>
          </div>
        </header>
        <div className="skeleton">
          <div className="skeleton-line w-80" />
          <div className="skeleton-line w-60" />
          <div className="skeleton-line w-100" />
        </div>
      </div>
    );
  }

  return (
    <div className="catalog-page">
      <header>
        <div className="header-left">
          <button
            className="btn-back"
            onClick={() => navigate("/meals")}
            aria-label="Back to Meals"
          >
            <span aria-hidden="true">‹</span>
          </button>
          <h1>{isEdit ? "Edit Meal" : "Create Meal"}</h1>
        </div>
      </header>

      {error && <p className="error">{error}</p>}

      <form className="custom-food-form" onSubmit={handleSubmit}>
        <label>
          Name
          <input
            type="text"
            value={name}
            onChange={(e) => setName(e.target.value)}
            placeholder="Meal name"
          />
        </label>

        <label>
          Notes
          <input
            type="text"
            value={notes}
            onChange={(e) => setNotes(e.target.value)}
            placeholder="Optional notes"
          />
        </label>

        <div className="detail-section">
          <h2>Total Quantity (optional)</h2>
          <div className="amount-unit-row">
            <input
              className="amount-input"
              type="number"
              value={totalQty}
              onChange={(e) => setTotalQty(e.target.value)}
              placeholder="Amount"
            />
            <select
              className="unit-select"
              value={totalUnit}
              onChange={(e) => setTotalUnit(e.target.value)}
            >
              <option value="g">g</option>
              <option value="kg">kg</option>
              <option value="ml">ml</option>
              <option value="cup">cup</option>
              <option value="tbsp">tbsp</option>
              <option value="tsp">tsp</option>
              <option value="piece">piece</option>
              <option value="packet">packet</option>
              <option value="serving">serving</option>
            </select>
          </div>
        </div>

        <div className="detail-section">
          <div className="section-header">
            <h2>Components</h2>
            <button type="button" onClick={addComponent}>
              + Add Component
            </button>
          </div>

          {components.map((comp, idx) => (
            <div key={idx} className="nutrient-row" style={{ flexWrap: "wrap" }}>
              <div style={{ flex: 2, minWidth: "180px", position: "relative" }}>
                <input
                  type="text"
                  value={comp.searchQuery}
                  onChange={(e) => handleSearchChange(e.target.value, idx)}
                  placeholder="Search product..."
                  style={{ width: "100%" }}
                />
                {comp.searchResults.length > 0 && (
                  <div
                    style={{
                      position: "absolute",
                      top: "100%",
                      left: 0,
                      right: 0,
                      background: "#fff",
                      border: "1px solid #ccc",
                      borderRadius: "4px",
                      zIndex: 10,
                      maxHeight: "200px",
                      overflowY: "auto",
                    }}
                  >
                    {comp.searchResults.map((r) => (
                      <button
                        key={r.id}
                        type="button"
                        onClick={() => selectProduct(r, idx)}
                        style={{
                          display: "block",
                          width: "100%",
                          padding: "0.5rem",
                          textAlign: "left",
                          border: "none",
                          background: "transparent",
                          cursor: "pointer",
                          fontSize: "0.8125rem",
                          borderBottom: "1px solid #f0f0f0",
                        }}
                      >
                        <strong>{r.name}</strong>
                        {r.brand && (
                          <span style={{ color: "#888", marginLeft: "0.25rem" }}>
                            — {r.brand}
                          </span>
                        )}
                      </button>
                    ))}
                  </div>
                )}
              </div>
              <input
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
                style={{ width: "80px" }}
              />
              <select
                value={comp.unit}
                onChange={(e) =>
                  setComponents((prev) =>
                    prev.map((r, i) =>
                      i === idx ? { ...r, unit: e.target.value } : r,
                    ),
                  )
                }
                style={{ width: "80px" }}
              >
                <option value="g">g</option>
                <option value="kg">kg</option>
                <option value="ml">ml</option>
                <option value="cup">cup</option>
                <option value="tbsp">tbsp</option>
                <option value="tsp">tsp</option>
                <option value="piece">piece</option>
                <option value="packet">packet</option>
                <option value="serving">serving</option>
              </select>
              {components.length > 1 && (
                <button
                  type="button"
                  className="btn-danger-sm"
                  onClick={() => removeComponent(idx)}
                >
                  ×
                </button>
              )}
            </div>
          ))}
        </div>

        <button
          type="submit"
          className="btn-primary"
          disabled={submitting}
          style={{ alignSelf: "flex-start" }}
        >
          {submitting
            ? "Saving..."
            : isEdit
              ? "Update Meal"
              : "Create Meal"}
        </button>
      </form>
    </div>
  );
}
