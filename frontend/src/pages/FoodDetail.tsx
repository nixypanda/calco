import { useState, useEffect } from "react";
import { useParams, useNavigate, useLocation } from "react-router-dom";
import { getFoodDetail, deleteCustomFood, listUnits } from "../api/foods";
import { createLog } from "../api/logs";
import type { ProductDetail, UnitItem } from "../api/foods";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Card } from "@/components/ui/card";
import { Badge } from "@/components/ui/badge";
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table";

const MEAL_SLOTS = [
  { value: "breakfast", label: "Breakfast" },
  { value: "lunch", label: "Lunch" },
  { value: "dinner", label: "Dinner" },
  { value: "snack", label: "Snack" },
] as const;

export function FoodDetail() {
  const { id } = useParams<{ id: string }>();
  const navigate = useNavigate();
  const location = useLocation();
  const [food, setFood] = useState<ProductDetail | null>(null);
  const [units, setUnits] = useState<UnitItem[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState("");
  const [deleting, setDeleting] = useState(false);
  const [logAmount, setLogAmount] = useState("1");
  const [logUnit, setLogUnit] = useState("g");
  const [logSlot, setLogSlot] = useState(
    (location.state as { mealSlot?: string } | null)?.mealSlot ?? "__none__",
  );
  const [logging, setLogging] = useState(false);

  useEffect(() => {
    if (!id) return;
    setLoading(true);
    setError("");
    Promise.all([getFoodDetail(id), listUnits()])
      .then(([foodData, unitData]) => {
        setFood(foodData);
        setUnits(unitData.items);
        setLogUnit(foodData.default_unit ?? "g");
      })
      .catch((err: unknown) => {
        setError(err instanceof Error ? err.message : "Failed to load food");
      })
      .finally(() => setLoading(false));
  }, [id]);

  const handleLog = async () => {
    if (!id || !food) return;
    setLogging(true);
    setError("");
    try {
      await createLog({
        logged_at: new Date().toISOString(),
        meal_slot: logSlot === "__none__" ? undefined : logSlot,
        item: { type: "product", id },
        quantity: { amount: logAmount, unit: logUnit },
      });
      navigate("/home");
    } catch (err: unknown) {
      setError(err instanceof Error ? err.message : "Failed to log food");
    } finally {
      setLogging(false);
    }
  };

  const handleDelete = async () => {
    if (!id || !food) return;
    if (!window.confirm(`Delete "${food.name}"? This cannot be undone.`)) return;
    setDeleting(true);
    try {
      await deleteCustomFood(id);
      navigate("/search", { replace: true });
    } catch (err: unknown) {
      setError(err instanceof Error ? err.message : "Failed to delete");
    } finally {
      setDeleting(false);
    }
  };

  if (loading) {
    return (
      <div className="w-full max-w-[760px] mx-auto p-4 pt-[calc(1rem+env(safe-area-inset-top))] pb-[calc(1.5rem+env(safe-area-inset-bottom))]">
        <header className="flex items-center justify-between gap-4 mb-4">
          <div className="flex items-center gap-2.5 min-w-0">
            <button
            className="inline-flex items-center justify-center min-w-[44px] min-h-[44px] pr-2 bg-transparent border-0 rounded-xl text-brand cursor-pointer text-base font-bold hover:bg-brand/8"
            onClick={() => navigate("/home")}
            aria-label="Back to Diary"
          >
            <span aria-hidden="true" className="text-[2rem] leading-[0.8]">‹</span>
          </button>
            <h1 className="text-foreground text-[1.75rem] max-sm:text-[1.5rem] font-extrabold">Food Detail</h1>
          </div>
        </header>
        <main>
          <div className="flex flex-col gap-3">
            <div className="skeleton-line w-4/5" />
            <div className="skeleton-line w-3/5" />
            <div className="skeleton-line w-full" />
          </div>
        </main>
      </div>
    );
  }

  if (error && !food) {
    return (
      <div className="w-full max-w-[760px] mx-auto p-4 pt-[calc(1rem+env(safe-area-inset-top))] pb-[calc(1.5rem+env(safe-area-inset-bottom))]">
        <header className="flex items-center justify-between gap-4 mb-4">
          <div className="flex items-center gap-2.5 min-w-0">
            <button
            className="inline-flex items-center justify-center min-w-[44px] min-h-[44px] pr-2 bg-transparent border-0 rounded-xl text-brand cursor-pointer text-base font-bold hover:bg-brand/8"
            onClick={() => navigate("/home")}
            aria-label="Back to Diary"
          >
            <span aria-hidden="true" className="text-[2rem] leading-[0.8]">‹</span>
          </button>
            <h1 className="text-foreground text-[1.75rem] max-sm:text-[1.5rem] font-extrabold">Food Detail</h1>
          </div>
        </header>
        <main>
          <p className="mb-4 p-3 bg-red-50 border border-red-200 rounded-xl text-red-500 font-semibold text-sm">{error}</p>
        </main>
      </div>
    );
  }

  if (!food) {
    return (
      <div className="w-full max-w-[760px] mx-auto p-4 pt-[calc(1rem+env(safe-area-inset-top))] pb-[calc(1.5rem+env(safe-area-inset-bottom))]">
        <header className="flex items-center justify-between gap-4 mb-4">
          <div className="flex items-center gap-2.5 min-w-0">
            <button
            className="inline-flex items-center justify-center min-w-[44px] min-h-[44px] pr-2 bg-transparent border-0 rounded-xl text-brand cursor-pointer text-base font-bold hover:bg-brand/8"
            onClick={() => navigate("/home")}
            aria-label="Back to Diary"
          >
            <span aria-hidden="true" className="text-[2rem] leading-[0.8]">‹</span>
          </button>
            <h1 className="text-foreground text-[1.75rem] max-sm:text-[1.5rem] font-extrabold">Food Detail</h1>
          </div>
        </header>
        <main>
          <p className="flex flex-col items-center justify-center gap-3.5 py-10 px-4 text-[#8e8e93] dark:text-[#86868b] text-sm text-center">Food not found.</p>
        </main>
      </div>
    );
  }

  const isCustom = food.source === "USER";

  return (
    <div className="w-full max-w-[760px] mx-auto p-4 pt-[calc(1rem+env(safe-area-inset-top))] pb-[calc(1.5rem+env(safe-area-inset-bottom))]">
      <header className="flex items-center justify-between gap-4 mb-4">
        <div className="flex items-center gap-2.5 min-w-0">
          <button
            className="inline-flex items-center justify-center min-w-[44px] min-h-[44px] pr-2 bg-transparent border-0 rounded-xl text-brand cursor-pointer text-base font-bold hover:bg-brand/8"
            onClick={() => navigate("/home")}
            aria-label="Back to Diary"
          >
            <span aria-hidden="true" className="text-[2rem] leading-[0.8]">‹</span>
          </button>
          <h1 className="text-foreground text-[1.75rem] max-sm:text-[1.5rem] font-extrabold">{food.name}</h1>
        </div>
      </header>

      <main>
        <div className="mb-5 flex flex-col gap-2">
          <div className="flex items-center flex-wrap gap-1.5">
            {food.brand && <span className="text-muted-foreground text-sm">{food.brand}</span>}
            {food.category && (
              <Badge variant="secondary">{food.category}</Badge>
            )}
            {isCustom && <Badge variant="secondary" className="bg-green-100 text-green-800 hover:bg-green-100">Custom</Badge>}
          </div>
          {food.serving_size_g && (
            <p className="text-muted-foreground text-sm">
              Serving size: {food.serving_size_g}g
            </p>
          )}
        </div>

        <section className="mb-5">
          <h2>Nutrition per 100g</h2>
          <Table>
            <TableHeader>
              <TableRow>
                <TableHead>Nutrient</TableHead>
                <TableHead className="text-right w-[92px]">Amount</TableHead>
                <TableHead className="text-right w-[92px]">Unit</TableHead>
              </TableRow>
            </TableHeader>
            <TableBody>
              {food.nutrients.map((n) => (
                <TableRow key={n.code}>
                  <TableCell>{n.code.replace(/_/g, " ").toLowerCase()}</TableCell>
                  <TableCell className="text-right">{n.amount_per_100g}</TableCell>
                  <TableCell className="text-right">{n.unit || "-"}</TableCell>
                </TableRow>
              ))}
            </TableBody>
          </Table>
        </section>

        {food.servings.length > 0 && (
          <section className="mb-5">
            <h2>Servings</h2>
            <div className="flex flex-col gap-3">
              {food.servings.map((s, i) => (
                <Card key={i} className="flex items-center justify-between gap-4 min-h-[50px] p-3">
                  <span className="font-bold">{s.label}</span>
                  <span className="text-muted-foreground text-sm">
                    {s.quantity} {s.unit} ({s.grams}g)
                  </span>
                </Card>
              ))}
            </div>
          </section>
        )}

        <section className="mb-5">
          <h2>Log Food</h2>
          <div className="flex flex-col gap-3.5">
            <div className="flex flex-col gap-1.5">
              <label>Meal</label>
              <Select value={logSlot} onValueChange={setLogSlot}>
                <SelectTrigger>
                  <SelectValue placeholder="No meal slot" />
                </SelectTrigger>
                <SelectContent>
                  <SelectItem value="__none__">No meal slot</SelectItem>
                  {MEAL_SLOTS.map((s) => (
                    <SelectItem key={s.value} value={s.value}>
                      {s.label}
                    </SelectItem>
                  ))}
                </SelectContent>
              </Select>
            </div>
            <div className="flex flex-col gap-1.5">
              <label>Amount</label>
              <div className="flex gap-2.5 items-stretch max-sm:flex-col">
                <Input
                  type="number"
                  className="flex-1 min-w-0"
                  value={logAmount}
                  onChange={(e) => setLogAmount(e.target.value)}
                  min={0}
                  step="any"
                  placeholder="Amount"
                />
                <Select value={logUnit} onValueChange={setLogUnit}>
                  <SelectTrigger className="w-[132px] flex-none">
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
            <Button onClick={handleLog} disabled={logging}>
              {logging ? "Logging..." : "Log Food"}
            </Button>
            {error && <p className="mb-4 p-3 bg-red-50 border border-red-200 rounded-xl text-red-500 font-semibold text-sm">{error}</p>}
          </div>
        </section>

        {isCustom && (
          <section className="mb-5">
            <h2>Manage Food</h2>
            <div className="flex flex-wrap gap-2.5">
              <Button
                variant="outline"
                onClick={() => navigate(`/foods/custom/${id}/edit`)}
              >
                Edit
              </Button>
              <Button
                variant="destructive"
                onClick={handleDelete}
                disabled={deleting}
              >
                {deleting ? "Deleting..." : "Delete"}
              </Button>
            </div>
          </section>
        )}
      </main>
    </div>
  );
}
