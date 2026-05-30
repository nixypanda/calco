import { useState, useEffect, useCallback } from "react";
import { useNavigate, useParams } from "react-router-dom";
import { getMeal, deleteMeal, getMealNutrients } from "../api/meals";
import { getFoodDetail } from "../api/foods";
import { createLog } from "../api/logs";
import type { MealResponse, MealNutritionResponse } from "../api/meals";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Card } from "@/components/ui/card";
import { Skeleton } from "@/components/ui/skeleton";
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
  DialogTrigger,
} from "@/components/ui/dialog";
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table";
import { ErrorBanner } from "@/components/ErrorBanner";
import { PageHeader } from "@/components/PageHeader";
import { EmptyState } from "@/components/EmptyState";

export function MealDetail() {
  const { id } = useParams<{ id: string }>();
  const navigate = useNavigate();

  const [meal, setMeal] = useState<MealResponse | null>(null);
  const [productNames, setProductNames] = useState<Record<string, string>>({});
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState("");

  const [logAmount, setLogAmount] = useState("100");
  const [logUnit] = useState("g");
  const [nutrients, setNutrients] = useState<MealNutritionResponse | null>(null);
  const [nutrientsLoading, setNutrientsLoading] = useState(false);
  const [nutrientsError, setNutrientsError] = useState("");

  const [deleting, setDeleting] = useState(false);
  const [showConfirm, setShowConfirm] = useState(false);
  const [deleteError, setDeleteError] = useState("");

  const [logging, setLogging] = useState(false);
  const [logError, setLogError] = useState("");

  const fetchMeal = useCallback(async () => {
    if (!id) return;
    setLoading(true);
    setError("");
    try {
      const mealData = await getMeal(id);
      if (!mealData) {
        setMeal(null);
        setLoading(false);
        return;
      }
      setMeal(mealData);

      const productIds = [
        ...new Set(
          mealData.components.filter((c) => c.item.type === "product").map((c) => c.item.id),
        ),
      ];
      if (productIds.length > 0) {
        const details = await Promise.all(
          productIds.map((pid) => getFoodDetail(pid).catch(() => null)),
        );
        const nameMap: Record<string, string> = {};
        for (const d of details) if (d) nameMap[d.id] = d.name;
        setProductNames(nameMap);
      }
    } catch (err: unknown) {
      setError(err instanceof Error ? err.message : "Failed to load meal");
    } finally {
      setLoading(false);
    }
  }, [id]);

  useEffect(() => {
    fetchMeal();
  }, [fetchMeal]);

  const handleCalculate = useCallback(async () => {
    if (!id) return;
    setNutrientsLoading(true);
    setNutrientsError("");
    try {
      const result = await getMealNutrients(id, logAmount, logUnit);
      setNutrients(result);
    } catch (err: unknown) {
      setNutrientsError(err instanceof Error ? err.message : "Failed to calculate nutrients");
    } finally {
      setNutrientsLoading(false);
    }
  }, [id, logAmount, logUnit]);

  const handleLog = useCallback(async () => {
    if (!id) return;
    setLogging(true);
    setLogError("");
    try {
      await createLog({
        logged_at: new Date().toISOString(),
        meal_slot: undefined,
        notes: undefined,
        item: { type: "meal", id },
        quantity: { amount: logAmount, unit: logUnit },
      });
      navigate("/home");
    } catch (err: unknown) {
      setLogError(err instanceof Error ? err.message : "Failed to log meal");
    } finally {
      setLogging(false);
    }
  }, [id, logAmount, logUnit, navigate]);

  const handleDelete = useCallback(async () => {
    if (!id) return;
    setDeleting(true);
    setDeleteError("");
    try {
      await deleteMeal(id);
      navigate("/meals");
    } catch (err: unknown) {
      setDeleteError(err instanceof Error ? err.message : "Failed to delete meal");
    } finally {
      setDeleting(false);
    }
  }, [id, navigate]);

  const goMeals = () => navigate("/meals");

  if (loading) {
    return (
      <div className="page">
        <PageHeader title="Meal" onBack={goMeals} backLabel="Back to Meals" />
        <div className="flex flex-col gap-3">
          <Skeleton className="h-4 w-4/5" />
          <Skeleton className="h-4 w-3/5" />
          <Skeleton className="h-4 w-full" />
        </div>
      </div>
    );
  }

  if (error) {
    return (
      <div className="page">
        <PageHeader title="Meal" onBack={goMeals} backLabel="Back to Meals" />
        <ErrorBanner message={error} />
      </div>
    );
  }

  if (!meal) {
    return (
      <div className="page">
        <PageHeader title="Meal" onBack={goMeals} backLabel="Back to Meals" />
        <EmptyState>Meal not found.</EmptyState>
      </div>
    );
  }

  return (
    <div className="page">
      <PageHeader title={meal.name} onBack={goMeals} backLabel="Back to Meals">
        <Button variant="outline" onClick={() => navigate(`/meals/${id}/edit`)}>
          Edit
        </Button>
        <Dialog open={showConfirm} onOpenChange={setShowConfirm}>
          <DialogTrigger asChild>
            <Button variant="destructive">Delete</Button>
          </DialogTrigger>
          <DialogContent>
            <DialogHeader>
              <DialogTitle>Delete meal?</DialogTitle>
              <DialogDescription>This action cannot be undone.</DialogDescription>
            </DialogHeader>
            {deleteError && <ErrorBanner message={deleteError} />}
            <DialogFooter>
              <Button
                variant="outline"
                onClick={() => {
                  setShowConfirm(false);
                  setDeleteError("");
                }}
              >
                Cancel
              </Button>
              <Button variant="destructive" onClick={handleDelete} disabled={deleting}>
                {deleting ? "Deleting..." : "Confirm Delete"}
              </Button>
            </DialogFooter>
          </DialogContent>
        </Dialog>
      </PageHeader>

      {meal.notes && (
        <p className="text-muted-foreground text-sm mb-4">{meal.notes}</p>
      )}

      <section className="mb-5">
        <h2>Components</h2>
        <div className="flex flex-col gap-3">
          {meal.components.map((comp) => (
            <Card key={comp.id} className="flex items-center justify-between gap-4 p-3">
              <span className="font-bold">{productNames[comp.item.id] ?? "Loading..."}</span>
              <span className="text-muted-foreground text-sm">
                {comp.quantity.amount} {comp.quantity.unit}
              </span>
            </Card>
          ))}
        </div>
      </section>

      <section className="mb-5">
        <h2>Log this meal</h2>
        <div className="flex flex-col gap-3.5">
          <div className="flex gap-2.5">
            <Input
              type="number"
              value={logAmount}
              onChange={(e) => setLogAmount(e.target.value)}
              placeholder="Amount"
              className="flex-1"
            />
            <Select value={logUnit} disabled>
              <SelectTrigger className="w-32 flex-none">
                <SelectValue />
              </SelectTrigger>
              <SelectContent>
                <SelectItem value="g">g</SelectItem>
              </SelectContent>
            </Select>
            <Button onClick={handleCalculate} disabled={nutrientsLoading}>
              {nutrientsLoading ? "..." : "Calculate"}
            </Button>
          </div>
          {nutrientsError && <ErrorBanner message={nutrientsError} />}
          {nutrients && (
            <>
              <Table>
                <TableHeader>
                  <TableRow>
                    <TableHead>Nutrient</TableHead>
                    <TableHead className="text-right w-24">Amount</TableHead>
                    <TableHead className="text-right w-24">Unit</TableHead>
                  </TableRow>
                </TableHeader>
                <TableBody>
                  {nutrients.nutrients.map((n) => (
                    <TableRow key={n.code}>
                      <TableCell>{n.code}</TableCell>
                      <TableCell className="text-right">{n.amount}</TableCell>
                      <TableCell className="text-right">{n.unit}</TableCell>
                    </TableRow>
                  ))}
                </TableBody>
              </Table>
              <Button onClick={handleLog} disabled={logging}>
                {logging ? "Logging..." : "Log Meal"}
              </Button>
              {logError && <ErrorBanner message={logError} />}
            </>
          )}
        </div>
      </section>
    </div>
  );
}
