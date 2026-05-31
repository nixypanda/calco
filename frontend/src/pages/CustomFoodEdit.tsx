import { useState, useEffect, type SubmitEvent } from "react";
import { useParams, useNavigate } from "react-router-dom";
import {
  getFoodDetail,
  updateCustomFood,
  listNutrients,
  listUnits,
} from "../api/foods";
import type { NutrientItem, UnitItem } from "../api/foods";
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
import { formatCategoriesInput, parseCategoriesInput } from "@/lib/categories";

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

export function CustomFoodEdit() {
  const { id } = useParams<{ id: string }>();
  const navigate = useNavigate();
  const [nutrients, setNutrients] = useState<NutrientItem[]>([]);
  const [units, setUnits] = useState<UnitItem[]>([]);
  const [loading, setLoading] = useState(true);
  const [name, setName] = useState("");
  const [brand, setBrand] = useState("");
  const [category, setCategory] = useState("");
  const [servingSizeG, setServingSizeG] = useState("");
  const [defaultQty, setDefaultQty] = useState("");
  const [defaultUnit, setDefaultUnit] = useState("g");
  const [nutrientRows, setNutrientRows] = useState<NutrientRow[]>([]);
  const [servingRows, setServingRows] = useState<ServingRow[]>([]);
  const [submitting, setSubmitting] = useState(false);
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
        setName(food.name);
        setBrand(food.brand ?? "");
        setCategory(formatCategoriesInput(food.categories));
        setServingSizeG(food.serving_size_g ?? "");
        setDefaultQty(food.default_quantity ?? "");
        setDefaultUnit(food.default_unit ?? "g");
        setNutrientRows(
          food.nutrients.length > 0
            ? food.nutrients.map((n) => ({
                code: n.code,
                amount_per_100g: n.amount_per_100g,
              }))
            : [{ code: "", amount_per_100g: "" }],
        );
        setServingRows(
          food.servings.map((s) => ({
            label: s.label,
            quantity: s.quantity,
            unit: s.unit,
            grams: s.grams,
          })),
        );
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
    if (!id) {
      setError("Missing food id in URL");
      return;
    }
    if (!name.trim()) {
      setError("Name is required");
      return;
    }

    const validNutrients = nutrientRows.filter((r) => r.code && r.amount_per_100g);
    const validServings = servingRows.filter((r) => r.label && r.quantity && r.grams);

    setSubmitting(true);
    try {
      const res = await updateCustomFood(id, {
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
      setError(err instanceof Error ? err.message : "Failed to update food");
    } finally {
      setSubmitting(false);
    }
  };

  const goHome = () => navigate("/home");

  if (loading) {
    return (
      <div className="page">
        <PageHeader title="Edit Custom Food" onBack={goHome} backLabel="Back to Diary" />
        <div className="flex flex-col gap-3">
          <Skeleton className="h-4 w-4/5" />
          <Skeleton className="h-4 w-3/5" />
        </div>
      </div>
    );
  }

  return (
    <div className="page">
      <PageHeader title="Edit Custom Food" onBack={goHome} backLabel="Back to Diary" />

      {error && <ErrorBanner message={error} />}

      <form onSubmit={handleSubmit} className="flex flex-col gap-3.5">
        <section className="mb-5">
          <h2>Basic Info</h2>
          <div className="flex flex-col gap-2">
            <div className="flex flex-col gap-1.5">
              <Label htmlFor="cfe-name">Name *</Label>
              <Input
                id="cfe-name"
                value={name}
                onChange={(e) => setName(e.target.value)}
                required
                autoFocus
                disabled={submitting}
              />
            </div>
            <div className="flex flex-col gap-1.5">
              <Label htmlFor="cfe-brand">Brand</Label>
              <Input
                id="cfe-brand"
                value={brand}
                onChange={(e) => setBrand(e.target.value)}
                disabled={submitting}
              />
            </div>
            <div className="flex flex-col gap-1.5">
              <Label htmlFor="cfe-category">Category</Label>
              <Input
                id="cfe-category"
                value={category}
                onChange={(e) => setCategory(e.target.value)}
                disabled={submitting}
              />
            </div>
          </div>
        </section>

        <section className="mb-5">
          <h2>Portion Info</h2>
          <div className="flex flex-col gap-2">
            <div className="flex flex-col gap-1.5">
              <Label htmlFor="cfe-serving">Serving Size (g)</Label>
              <Input
                id="cfe-serving"
                type="number"
                value={servingSizeG}
                onChange={(e) => setServingSizeG(e.target.value)}
                min={0}
                step="any"
                disabled={submitting}
              />
            </div>
            <div className="flex flex-col gap-1.5">
              <Label htmlFor="cfe-defqty">Default Quantity</Label>
              <Input
                id="cfe-defqty"
                type="number"
                value={defaultQty}
                onChange={(e) => setDefaultQty(e.target.value)}
                min={0}
                step="any"
                disabled={submitting}
              />
            </div>
            <div className="flex flex-col gap-1.5">
              <Label>Default Unit</Label>
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
          </div>
        </section>

        <section className="mb-5">
          <div className="flex items-center justify-between gap-3 mb-3.5">
            <h2 className="mb-0">Nutrients (per 100g)</h2>
            <Button
              type="button"
              variant="outline"
              size="sm"
              onClick={addNutrientRow}
              disabled={submitting}
            >
              + Add Nutrient
            </Button>
          </div>
          {nutrientRows.map((row, i) => (
            <div key={i} className="flex gap-2.5 items-center mb-2.5">
              <Select
                value={row.code}
                onValueChange={(v) => updateNutrientRow(i, "code", v)}
                disabled={submitting}
              >
                <SelectTrigger className="flex-1">
                  <SelectValue placeholder="Select nutrient..." />
                </SelectTrigger>
                <SelectContent>
                  {nutrients.map((n) => (
                    <SelectItem key={n.code} value={n.code}>{n.name}</SelectItem>
                  ))}
                </SelectContent>
              </Select>
              <Input
                type="number"
                placeholder="Amount per 100g"
                value={row.amount_per_100g}
                onChange={(e) => updateNutrientRow(i, "amount_per_100g", e.target.value)}
                min={0}
                step="any"
                disabled={submitting}
                className="flex-1"
              />
              <Button
                type="button"
                variant="ghost"
                size="icon"
                className="text-destructive"
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
            <h2 className="mb-0">Servings</h2>
            <Button
              type="button"
              variant="outline"
              size="sm"
              onClick={addServingRow}
              disabled={submitting}
            >
              + Add Serving
            </Button>
          </div>
          {servingRows.map((row, i) => (
            <div key={i} className="flex gap-2.5 items-center mb-2.5 flex-wrap">
              <Input
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
                onChange={(e) => updateServingRow(i, "quantity", e.target.value)}
                min={0}
                step="any"
                disabled={submitting}
                className="flex-1"
              />
              <Select
                value={row.unit}
                onValueChange={(v) => updateServingRow(i, "unit", v)}
                disabled={submitting}
              >
                <SelectTrigger className="w-24 flex-none">
                  <SelectValue />
                </SelectTrigger>
                <SelectContent>
                  {units.map((u) => (
                    <SelectItem key={u.code} value={u.code}>{u.code}</SelectItem>
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
                size="icon"
                className="text-destructive"
                onClick={() => removeServingRow(i)}
                disabled={submitting}
              >
                ×
              </Button>
            </div>
          ))}
        </section>

        <Button type="submit" disabled={submitting} className="self-start">
          {submitting ? "Saving..." : "Save Changes"}
        </Button>
      </form>
    </div>
  );
}
