import { Button, Container, Paper, Skeleton, Stack, Text } from "@mantine/core";
import { useCallback, useEffect, useState } from "react";
import { useNavigate } from "react-router-dom";
import { EmptyState } from "@/components/EmptyState";
import { ErrorBanner } from "@/components/ErrorBanner";
import { PageHeader } from "@/components/PageHeader";
import { plural } from "@/lib/plural";
import type { MealResponse } from "../api/meals";
import { listMeals } from "../api/meals";

export function Meals() {
  const navigate = useNavigate();
  const [meals, setMeals] = useState<MealResponse[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState("");

  const fetchMeals = useCallback(async () => {
    setLoading(true);
    setError("");
    try {
      const res = await listMeals();
      setMeals(res.items);
    } catch (err: unknown) {
      setError(err instanceof Error ? err.message : "Failed to load meals");
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    fetchMeals();
  }, [fetchMeals]);

  const goHome = () => navigate("/home");

  if (loading) {
    return (
      <Container p="md">
        <PageHeader title="Meals" onBack={goHome} backLabel="Back to Diary" />
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
        <PageHeader title="Meals" onBack={goHome} backLabel="Back to Diary" />
        <ErrorBanner message={error} />
      </Container>
    );
  }

  return (
    <Container p="md">
      <PageHeader title="Meals" onBack={goHome} backLabel="Back to Diary">
        <Button onClick={() => navigate("/meals/new")}>Create Meal</Button>
      </PageHeader>

      {meals.length === 0 && (
        <EmptyState>
          No meals yet. Create a meal to log common combinations faster.
        </EmptyState>
      )}

      <Stack gap="sm">
        {meals.map((meal) => (
          <Paper
            key={meal.id}
            p="md"
            style={{ cursor: "pointer" }}
            onClick={() => navigate(`/meals/${meal.id}`)}
          >
            <Stack gap={2} miw={0}>
              <Text fw={700} truncate>
                {meal.name}
              </Text>
              <Text c="dimmed" size="sm">
                {plural(meal.components.length, "component")}
                {meal.notes ? ` — ${meal.notes}` : ""}
              </Text>
            </Stack>
          </Paper>
        ))}
      </Stack>
    </Container>
  );
}
