import { useState, useEffect } from "react";
import { useParams, useNavigate, useLocation } from "react-router-dom";
import { getFoodDetail, deleteCustomFood, listUnits } from "../api/foods";
import { createLog } from "../api/logs";
import type { ProductDetail, UnitItem } from "../api/foods";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Card } from "@/components/ui/card";
import { Skeleton } from "@/components/ui/skeleton";
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
import { ErrorBanner } from "@/components/ErrorBanner";

const MEAL_SLOTS = [
  { value: "breakfast", label: "Breakfast" },
  { value: "lunch", label: "Lunch" },
  { value: "dinner", label: "Dinner" },
  { value: "snack", label: "Snack" },
] as const;

const wrapperClass = "w-full max-w-[760px] mx-auto p-4 pt-[calc(1rem+env(safe-area-inset-top))] pb-[calc(1.5rem+env(safe-area-inset-bottom))]";

function Header({ title, onBack }: { title: string; onBack: () => void }) {
  return (
    <header className="flex items-center justify-between gap-4 mb-4">
      <div className="flex items-center gap-2.5 min-w-0">
        <button
          className="inline-flex items-center justify-center min-w-[44px] min-h-[44px] pr-2 bg-transparent border-0 rounded-xl text-muted-foreground cursor-pointer text-base font-bold hover:bg-accent"
          onClick={onBack}
          aria-label="Back to Diary"
        >
          <span aria-hidden="true" className="text-[2rem] leading-[0.8]">‹</span>
        </button>
        <h1 className="text-foreground text-[1.75rem] max-sm:text-[1.5rem] font-extrabold">{title}</h1>
      </div>
    </header>
  );
}

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
    let cancelled = false;
    setLoading(true);
    setError("");
    Promise.all([getFoodDetail(id), listUnits()])
      .then(([foodData, unitData]) => {
        if (cancelled) return;
        setFood(foodData);
        setUnits(unitData.items);
        setLogUnit(foodData.default_unit ?? "g");
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

  const goHome = () => navigate("/home");

  if (loading) {
    return (
      <div className={wrapperClass}>
        <Header title="Food Detail" onBack={goHome} />
        <main>
          <div className="flex flex-col gap-3">
            <Skeleton className="h-4 w-4/5" />
            <Skeleton className="h-4 w-3/5" />
            <Skeleton className="h-4 w-full" />
          </div>
        </main>
      </div>
    );
  }

  if (error && !food) {
    return (
      <div className={wrapperClass}>
        <Header title="Food Detail" onBack={goHome} />
        <main><ErrorBanner message={error} /></main>
      </div>
    );
  }

  if (!food) {
    return (
      <div className={wrapperClass}>
        <Header title="Food Detail" onBack={goHome} />
        <main>
          <p className="flex flex-col items-center justify-center gap-3.5 py-10 px-4 text-muted-foreground text-sm text-center">Food not found.</p>
        </main>
      </div>
    );
  }

  const isCustom = food.source === "USER";
  const selectClass = "flex h-9 w-full rounded-md border border-input bg-transparent px-3 py-1 text-sm shadow-sm focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring disabled:cursor-not-allowed disabled:opacity-50";

  return (
    <div className={wrapperClass}>
      <Header title={food.name} onBack={goHome} />

      <main>
        <div className="mb-5 flex flex-col gap-2">
          <div className="flex items-center flex-wrap gap-1.5">
            {food.brand && <span className="text-muted-foreground text-sm">{food.brand}</span>}
            {food.category && <Badge variant="secondary">{food.category}</Badge>}
            {isCustom && <Badge variant="outline">Custom</Badge>}
          </div>
          {food.serving_size_g && (
            <p className="text-muted-foreground text-sm">Serving size: {food.serving_size_g}g</p>
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
              <label htmlFor="log-meal-slot">Meal</label>
              <select
                id="log-meal-slot"
                value={logSlot}
                onChange={(e) => setLogSlot(e.target.value)}
                className={selectClass}
              >
                <option value="__none__">No meal slot</option>
                {MEAL_SLOTS.map((s) => (
                  <option key={s.value} value={s.value}>{s.label}</option>
                ))}
              </select>
            </div>
            <div className="flex flex-col gap-1.5">
              <label htmlFor="log-amount">Amount</label>
              <div className="flex gap-2.5 items-stretch max-sm:flex-col">
                <Input
                  id="log-amount"
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
            {error && <ErrorBanner message={error} />}
          </div>
        </section>

        {isCustom && (
          <section className="mb-5">
            <h2>Manage Food</h2>
            <div className="flex flex-wrap gap-2.5">
              <Button variant="outline" onClick={() => navigate(`/foods/custom/${id}/edit`)}>
                Edit
              </Button>
              <Button variant="destructive" onClick={handleDelete} disabled={deleting}>
                {deleting ? "Deleting..." : "Delete"}
              </Button>
            </div>
          </section>
        )}
      </main>
    </div>
  );
}
