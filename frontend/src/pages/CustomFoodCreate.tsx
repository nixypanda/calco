import { useState, useEffect, type FormEvent } from "react";
import { useNavigate } from "react-router-dom";
import { createCustomFood, listNutrients, listUnits } from "../api/foods";
import type { NutrientItem, UnitItem } from "../api/foods";

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
    Promise.all([listNutrients(), listUnits()])
      .then(([n, u]) => {
        setNutrients(n.items);
        setUnits(u.items);
      })
      .catch(() => setError("Failed to load reference data"));
  }, []);

  const addNutrientRow = () => {
    setNutrientRows([...nutrientRows, { code: "", amount_per_100g: "" }]);
  };

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

  const addServingRow = () => {
    setServingRows([
      ...servingRows,
      { label: "", quantity: "", unit: "g", grams: "" },
    ]);
  };

  const removeServingRow = (i: number) => {
    setServingRows(servingRows.filter((_, idx) => idx !== i));
  };

  const updateServingRow = (
    i: number,
    field: keyof ServingRow,
    value: string,
  ) => {
    const rows = [...servingRows];
    rows[i] = { ...rows[i], [field]: value };
    setServingRows(rows);
  };

  const handleSubmit = async (e: FormEvent) => {
    e.preventDefault();
    setError("");

    if (!name.trim()) {
      setError("Name is required");
      return;
    }

    const validNutrients = nutrientRows.filter((r) => r.code && r.amount_per_100g);
    const validServings = servingRows.filter(
      (r) => r.label && r.quantity && r.grams,
    );

    setSubmitting(true);
    try {
      const res = await createCustomFood({
        name: name.trim(),
        brand: brand.trim() || null,
        category: category.trim() || null,
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
    <div className="catalog-page">
      <header>
        <div className="header-left">
          <button
            className="btn-back"
            onClick={() => navigate("/home")}
            aria-label="Back to Diary"
          >
            <span aria-hidden="true">‹</span>
          </button>
          <h1>Create Custom Food</h1>
        </div>
      </header>

      <main>
        {error && <p className="error">{error}</p>}

        <form onSubmit={handleSubmit} className="custom-food-form">
          <section className="detail-section">
            <h2>Basic Info</h2>
            <label>
              Name *
              <input
                type="text"
                value={name}
                onChange={(e) => setName(e.target.value)}
                required
                autoFocus
                disabled={submitting}
              />
            </label>
            <label>
              Brand
              <input
                type="text"
                value={brand}
                onChange={(e) => setBrand(e.target.value)}
                disabled={submitting}
              />
            </label>
            <label>
              Category
              <input
                type="text"
                value={category}
                onChange={(e) => setCategory(e.target.value)}
                disabled={submitting}
              />
            </label>
          </section>

          <section className="detail-section">
            <h2>Portion Info</h2>
            <label>
              Serving Size (g)
              <input
                type="number"
                value={servingSizeG}
                onChange={(e) => setServingSizeG(e.target.value)}
                min={0}
                step="any"
                disabled={submitting}
              />
            </label>
            <label>
              Default Quantity
              <input
                type="number"
                value={defaultQty}
                onChange={(e) => setDefaultQty(e.target.value)}
                min={0}
                step="any"
                disabled={submitting}
              />
            </label>
            <label>
              Default Unit
              <select
                value={defaultUnit}
                onChange={(e) => setDefaultUnit(e.target.value)}
                disabled={submitting}
              >
                {units.map((u) => (
                  <option key={u.code} value={u.code}>
                    {u.name} ({u.code})
                  </option>
                ))}
              </select>
            </label>
          </section>

          <section className="detail-section">
            <div className="section-header">
              <h2>Nutrients (per 100g)</h2>
              <button type="button" onClick={addNutrientRow} disabled={submitting}>
                + Add Nutrient
              </button>
            </div>
            {nutrientRows.map((row, i) => (
              <div key={i} className="nutrient-row">
                <select
                  value={row.code}
                  onChange={(e) => updateNutrientRow(i, "code", e.target.value)}
                  disabled={submitting}
                >
                  <option value="">Select nutrient...</option>
                  {nutrients.map((n) => (
                    <option key={n.code} value={n.code}>
                      {n.name}
                    </option>
                  ))}
                </select>
                <input
                  type="number"
                  placeholder="Amount per 100g"
                  value={row.amount_per_100g}
                  onChange={(e) =>
                    updateNutrientRow(i, "amount_per_100g", e.target.value)
                  }
                  min={0}
                  step="any"
                  disabled={submitting}
                />
                <button
                  type="button"
                  className="btn-danger-sm"
                  onClick={() => removeNutrientRow(i)}
                  disabled={nutrientRows.length <= 1 || submitting}
                >
                  ×
                </button>
              </div>
            ))}
          </section>

          <section className="detail-section">
            <div className="section-header">
              <h2>Servings</h2>
              <button type="button" onClick={addServingRow} disabled={submitting}>
                + Add Serving
              </button>
            </div>
            {servingRows.map((row, i) => (
              <div key={i} className="serving-row">
                <input
                  type="text"
                  placeholder="Label (e.g. scoop)"
                  value={row.label}
                  onChange={(e) => updateServingRow(i, "label", e.target.value)}
                  disabled={submitting}
                />
                <input
                  type="number"
                  placeholder="Qty"
                  value={row.quantity}
                  onChange={(e) =>
                    updateServingRow(i, "quantity", e.target.value)
                  }
                  min={0}
                  step="any"
                  disabled={submitting}
                />
                <select
                  value={row.unit}
                  onChange={(e) => updateServingRow(i, "unit", e.target.value)}
                  disabled={submitting}
                >
                  {units.map((u) => (
                    <option key={u.code} value={u.code}>
                      {u.code}
                    </option>
                  ))}
                </select>
                <input
                  type="number"
                  placeholder="Grams"
                  value={row.grams}
                  onChange={(e) => updateServingRow(i, "grams", e.target.value)}
                  min={0}
                  step="any"
                  disabled={submitting}
                />
                <button
                  type="button"
                  className="btn-danger-sm"
                  onClick={() => removeServingRow(i)}
                  disabled={submitting}
                >
                  ×
                </button>
              </div>
            ))}
          </section>

          <button type="submit" className="btn-primary" disabled={submitting}>
            {submitting ? "Creating..." : "Create Food"}
          </button>
        </form>
      </main>
    </div>
  );
}
