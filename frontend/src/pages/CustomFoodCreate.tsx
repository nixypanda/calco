import { useState, useEffect, type FormEvent } from "react";
import { useNavigate } from "react-router-dom";
import { createCustomFood, listNutrients, listUnits } from "../api/foods";
import type { NutrientItem, UnitItem } from "../api/foods";
import { Button } from "@/components/ui/button";
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
      if (failures.length > 0) {
        setError(`Failed to load ${failures.join(" and ")}`);
      }
    });
    return () => {
      cancelled = true;
    };
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
    <div className="w-full max-w-[760px] mx-auto p-4 pt-[calc(1rem+env(safe-area-inset-top))] pb-[calc(1.5rem+env(safe-area-inset-bottom))]">
      <header className="flex items-center justify-between gap-4 mb-4">
        <div className="flex items-center gap-2.5 min-w-0">
          <button
            className="inline-flex items-center justify-center min-w-[44px] min-h-[44px] pr-2 bg-transparent border-0 rounded-xl text-muted-foreground cursor-pointer text-base font-bold hover:bg-accent"
            onClick={() => navigate("/home")}
            aria-label="Back to Diary"
          >
            <span aria-hidden="true" className="text-[2rem] leading-[0.8]">‹</span>
          </button>
          <h1 className="text-foreground text-[1.75rem] max-sm:text-[1.5rem] font-extrabold">Create Custom Food</h1>
        </div>
      </header>

      <main>
        {error && <ErrorBanner message={error} />}

        <form onSubmit={handleSubmit} className="flex flex-col gap-3.5">
          <section className="mb-5">
            <h2>Basic Info</h2>
            <div className="flex flex-col gap-1.5 mb-2">
              <Label htmlFor="cf-name" className="text-xs font-bold text-muted-foreground">Name *</Label>
              <Input
                id="cf-name"
                type="text"
                value={name}
                onChange={(e) => setName(e.target.value)}
                required
                autoFocus
                disabled={submitting}
              />
            </div>
            <div className="flex flex-col gap-1.5 mb-2">
              <Label htmlFor="cf-brand" className="text-xs font-bold text-muted-foreground">Brand</Label>
              <Input
                id="cf-brand"
                type="text"
                value={brand}
                onChange={(e) => setBrand(e.target.value)}
                disabled={submitting}
              />
            </div>
            <div className="flex flex-col gap-1.5 mb-2">
              <Label htmlFor="cf-category" className="text-xs font-bold text-muted-foreground">Category</Label>
              <Input
                id="cf-category"
                type="text"
                value={category}
                onChange={(e) => setCategory(e.target.value)}
                disabled={submitting}
              />
            </div>
          </section>

          <section className="mb-5">
            <h2>Portion Info</h2>
            <div className="flex flex-col gap-1.5 mb-2">
              <Label htmlFor="cf-serving" className="text-xs font-bold text-muted-foreground">Serving Size (g)</Label>
              <Input
                id="cf-serving"
                type="number"
                value={servingSizeG}
                onChange={(e) => setServingSizeG(e.target.value)}
                min={0}
                step="any"
                disabled={submitting}
              />
            </div>
            <div className="flex flex-col gap-1.5 mb-2">
              <Label htmlFor="cf-defqty" className="text-xs font-bold text-muted-foreground">Default Quantity</Label>
              <Input
                id="cf-defqty"
                type="number"
                value={defaultQty}
                onChange={(e) => setDefaultQty(e.target.value)}
                min={0}
                step="any"
                disabled={submitting}
              />
            </div>
            <div className="flex flex-col gap-1.5 mb-2">
              <Label className="text-xs font-bold text-muted-foreground">Default Unit</Label>
              <Select value={defaultUnit} onValueChange={setDefaultUnit} disabled={submitting}>
                <SelectTrigger>
                  <SelectValue />
                </SelectTrigger>
                <SelectContent>
                  {units.map((u) => (
                    <SelectItem key={u.code} value={u.code}>
                      {u.name} ({u.code})
                    </SelectItem>
                  ))}
                </SelectContent>
              </Select>
            </div>
          </section>

          <section className="mb-5">
            <div className="flex items-center justify-between gap-3 mb-3.5">
              <h2>Nutrients (per 100g)</h2>
              <Button type="button" variant="outline" size="sm" onClick={addNutrientRow} disabled={submitting}>
                + Add Nutrient
              </Button>
            </div>
            {nutrientRows.map((row, i) => (
              <div key={i} className="flex gap-2.5 items-center mb-2.5">
                <Select
                  value={row.code}
                  onValueChange={(value) => updateNutrientRow(i, "code", value)}
                  disabled={submitting}
                >
                  <SelectTrigger className="flex-1">
                    <SelectValue placeholder="Select nutrient..." />
                  </SelectTrigger>
                  <SelectContent>
                    {nutrients.map((n) => (
                      <SelectItem key={n.code} value={n.code}>
                        {n.name}
                      </SelectItem>
                    ))}
                  </SelectContent>
                </Select>
                <Input
                  type="number"
                  placeholder="Amount per 100g"
                  value={row.amount_per_100g}
                  onChange={(e) =>
                    updateNutrientRow(i, "amount_per_100g", e.target.value)
                  }
                  min={0}
                  step="any"
                  disabled={submitting}
                  className="flex-1"
                />
                <Button
                  type="button"
                  variant="ghost"
                  className="w-11 h-11 p-0 text-destructive"
                  onClick={() => removeNutrientRow(i)}
                  disabled={nutrientRows.length <= 1 || submitting}
                >
                  ×
                </Button>
              </div>
            ))}
          </section>

          <section className="mb-5">
            <div className="flex items-center justify-between gap-3 mb-3.5">
              <h2>Servings</h2>
              <Button type="button" variant="outline" size="sm" onClick={addServingRow} disabled={submitting}>
                + Add Serving
              </Button>
            </div>
            {servingRows.map((row, i) => (
              <div key={i} className="flex gap-2.5 items-center mb-2.5 flex-wrap">
                <Input
                  type="text"
                  placeholder="Label (e.g. scoop)"
                  value={row.label}
                  onChange={(e) => updateServingRow(i, "label", e.target.value)}
                  disabled={submitting}
                  className="flex-1"
                />
                <Input
                  type="number"
                  placeholder="Qty"
                  value={row.quantity}
                  onChange={(e) =>
                    updateServingRow(i, "quantity", e.target.value)
                  }
                  min={0}
                  step="any"
                  disabled={submitting}
                  className="flex-1"
                />
                <Select
                  value={row.unit}
                  onValueChange={(value) => updateServingRow(i, "unit", value)}
                  disabled={submitting}
                >
                  <SelectTrigger className="w-[92px] flex-none">
                    <SelectValue />
                  </SelectTrigger>
                  <SelectContent>
                    {units.map((u) => (
                      <SelectItem key={u.code} value={u.code}>
                        {u.code}
                      </SelectItem>
                    ))}
                  </SelectContent>
                </Select>
                <Input
                  type="number"
                  placeholder="Grams"
                  value={row.grams}
                  onChange={(e) => updateServingRow(i, "grams", e.target.value)}
                  min={0}
                  step="any"
                  disabled={submitting}
                  className="flex-1"
                />
                <Button
                  type="button"
                  variant="ghost"
                  className="w-11 h-11 p-0 text-destructive"
                  onClick={() => removeServingRow(i)}
                  disabled={submitting}
                >
                  ×
                </Button>
              </div>
            ))}
          </section>

          <Button type="submit" disabled={submitting} className="self-start">
            {submitting ? "Creating..." : "Create Food"}
          </Button>
        </form>
      </main>
    </div>
  );
}
