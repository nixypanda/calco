import { useState, useEffect, useCallback } from "react";
import { useNavigate, useParams } from "react-router-dom";
import { getMeal, deleteMeal, getMealNutrients } from "../api/meals";
import { getFoodDetail } from "../api/foods";
import { createLog } from "../api/logs";
import type { MealResponse, MealNutritionResponse } from "../api/meals";
import {
  Button,
  TextInput,
  Paper,
  Skeleton,
  NativeSelect,
  Modal,
  Table,
  Container,
  Group,
  Stack,
  Text,
  Title,
} from "@mantine/core";
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
      <Container p="md">
        <PageHeader title="Meal" onBack={goMeals} backLabel="Back to Meals" />
        <Stack gap="sm">
          <Skeleton height={16} width="80%" />
          <Skeleton height={16} width="60%" />
          <Skeleton height={16} width="100%" />
        </Stack>
      </Container>
    );
  }

  if (error) {
    return (
      <Container p="md">
        <PageHeader title="Meal" onBack={goMeals} backLabel="Back to Meals" />
        <ErrorBanner message={error} />
      </Container>
    );
  }

  if (!meal) {
    return (
      <Container p="md">
        <PageHeader title="Meal" onBack={goMeals} backLabel="Back to Meals" />
        <EmptyState>Meal not found.</EmptyState>
      </Container>
    );
  }

  return (
    <Container p="md">
      <PageHeader title={meal.name} onBack={goMeals} backLabel="Back to Meals">
        <Button variant="outline" onClick={() => navigate(`/meals/${id}/edit`)}>
          Edit
        </Button>
        <Button color="red" onClick={() => setShowConfirm(true)}>Delete</Button>
        <Modal
          opened={showConfirm}
          onClose={() => {
            setShowConfirm(false);
            setDeleteError("");
          }}
          title="Delete meal?"
        >
          <Text c="dimmed" size="sm" mb="sm">
            This action cannot be undone.
          </Text>
          {deleteError && <ErrorBanner message={deleteError} />}
          <Group justify="flex-end" gap="xs" mt="sm">
            <Button
              variant="outline"
              onClick={() => {
                setShowConfirm(false);
                setDeleteError("");
              }}
            >
              Cancel
            </Button>
            <Button color="red" onClick={handleDelete} disabled={deleting}>
              {deleting ? "Deleting..." : "Confirm Delete"}
            </Button>
          </Group>
        </Modal>
      </PageHeader>

      {meal.notes && (
        <Text c="dimmed" size="sm" mb="md">
          {meal.notes}
        </Text>
      )}

      <Stack gap="lg" mb="lg">
        <Stack gap="sm">
          <Title order={2}>Components</Title>
          <Stack gap="sm">
            {meal.components.map((comp) => (
              <Paper key={comp.id} p="sm">
                <Group justify="space-between" gap="md">
                  <Text fw={700}>{productNames[comp.item.id] ?? "Loading..."}</Text>
                  <Text c="dimmed" size="sm">
                    {comp.quantity.amount} {comp.quantity.unit}
                  </Text>
                </Group>
              </Paper>
            ))}
          </Stack>
        </Stack>

        <Stack gap="sm">
          <Title order={2}>Log this meal</Title>
          <Stack gap="sm">
            <Group gap="xs">
              <TextInput
                type="number"
                value={logAmount}
                onChange={(e) => setLogAmount(e.target.value)}
                placeholder="Amount"
                style={{ flex: 1 }}
              />
              <NativeSelect
                value={logUnit}
                disabled
                data={[{ value: "g", label: "g" }]}
                w={128}
              />
              <Button onClick={handleCalculate} disabled={nutrientsLoading}>
                {nutrientsLoading ? "..." : "Calculate"}
              </Button>
            </Group>
            {nutrientsError && <ErrorBanner message={nutrientsError} />}
            {nutrients && (
              <>
                <Table>
                  <Table.Thead>
                    <Table.Tr>
                      <Table.Th>Nutrient</Table.Th>
                      <Table.Th ta="right" w={96}>Amount</Table.Th>
                      <Table.Th ta="right" w={96}>Unit</Table.Th>
                    </Table.Tr>
                  </Table.Thead>
                  <Table.Tbody>
                    {nutrients.nutrients.map((n) => (
                      <Table.Tr key={n.code}>
                        <Table.Td>{n.code}</Table.Td>
                        <Table.Td ta="right">{n.amount}</Table.Td>
                        <Table.Td ta="right">{n.unit}</Table.Td>
                      </Table.Tr>
                    ))}
                  </Table.Tbody>
                </Table>
                <Button onClick={handleLog} disabled={logging}>
                  {logging ? "Logging..." : "Log Meal"}
                </Button>
                {logError && <ErrorBanner message={logError} />}
              </>
            )}
          </Stack>
        </Stack>
      </Stack>
    </Container>
  );
}
