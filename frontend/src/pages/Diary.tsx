import {
  ActionIcon,
  Avatar,
  Box,
  Button,
  Container,
  Group,
  Menu,
  Paper,
  SimpleGrid,
  Skeleton,
  Stack,
  Text,
  Title,
  UnstyledButton,
} from "@mantine/core";
import { Moon, Sun } from "lucide-react";
import { useEffect, useRef, useState } from "react";
import { useNavigate, useSearchParams } from "react-router-dom";
import { EmptyState } from "@/components/EmptyState";
import { ErrorBanner } from "@/components/ErrorBanner";
import { MacroRing } from "@/components/MacroRing";
import {
  DEFAULT_CALORIE_GOAL,
  getCalories,
  getMacroTotals,
  getNutrientVal,
  MACRO_COLORS,
  MEAL_SLOTS,
  SUMMARY_CODES,
} from "@/lib/nutrition";
import { displayDate, formatDate, todayString } from "@/lib/time";
import { getFoodDetail } from "../api/foods";
import type { LogResponse, SummaryEntry } from "../api/logs";
import { getSummary, listLogs } from "../api/logs";
import { getMeal } from "../api/meals";
import { useAuth } from "../hooks/AuthContext";

function NutrientRing({
  label,
  value,
  unit,
  max,
  color,
  size = 80,
}: {
  label: string;
  value: number;
  unit: string;
  max: number;
  color: string;
  size?: number;
}) {
  const big = size >= 120;
  return (
    <Stack gap={4} align="center">
      <MacroRing
        segments={[{ value, color }]}
        total={max}
        size={size}
        strokeWidth={big ? 10 : 6}
      >
        <Text fw={800} size={big ? "xl" : "md"}>
          {Math.round(value)}
        </Text>
        <Text c="dimmed" fw={600} size="xs" tt="uppercase">
          {unit}
        </Text>
      </MacroRing>
      <Text c="dimmed" fw={500} size={big ? "sm" : "xs"}>
        {label}
      </Text>
    </Stack>
  );
}

function SlotMacroSummary({
  logs,
  mode,
  onToggle,
}: {
  logs: LogResponse[];
  mode: "grams" | "percent";
  onToggle: () => void;
}) {
  const m = getMacroTotals(logs);
  const fmt = (g: number, p: number) =>
    mode === "grams" ? `${g.toFixed(1)}g` : `${Math.round(p)}%`;
  return (
    <UnstyledButton
      onClick={onToggle}
      title="Toggle macro grams and percentages"
    >
      <Text c="dimmed" size="sm" fw={500}>
        carbs {fmt(m.carbs, m.carbsPct)} ⋅ protein{" "}
        {fmt(m.protein, m.proteinPct)} ⋅ fat {fmt(m.fat, m.fatPct)}
      </Text>
    </UnstyledButton>
  );
}

function getInitials(name: string): string {
  const words = name.trim().split(/\s+/).filter(Boolean);
  if (words.length === 0) return "?";
  if (words.length === 1) return words[0].slice(0, 2).toUpperCase();
  return `${words[0][0]}${words[1][0]}`.toUpperCase();
}

export function Diary() {
  const navigate = useNavigate();
  const [searchParams] = useSearchParams();
  const { identity, profile, logout } = useAuth();

  const getInitialDate = (): Date => {
    const dateParam = searchParams.get("date");
    if (dateParam) {
      const d = new Date(`${dateParam}T00:00:00`);
      if (!Number.isNaN(d.getTime())) return d;
    }
    const now = new Date();
    now.setHours(0, 0, 0, 0);
    return now;
  };

  const [currentDate, setCurrentDate] = useState(getInitialDate);
  const [logs, setLogs] = useState<LogResponse[]>([]);
  const [summary, setSummary] = useState<SummaryEntry[]>([]);
  const [foodNames, setFoodNames] = useState<Record<string, string>>({});
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState("");
  const [macroMode, setMacroMode] = useState<"grams" | "percent">("grams");
  const ringScrollRef = useRef<HTMLDivElement>(null);
  const [darkMode, setDarkMode] = useState(() => {
    const stored = localStorage.getItem("theme");
    if (stored === "dark") return true;
    if (stored === "light") return false;
    return window.matchMedia?.("(prefers-color-scheme: dark)").matches ?? false;
  });

  useEffect(() => {
    document.documentElement.classList.toggle("dark", darkMode);
    localStorage.setItem("theme", darkMode ? "dark" : "light");
  }, [darkMode]);

  const dateStr = formatDate(currentDate);
  const displayName = profile?.display_name ?? identity?.username ?? "User";

  useEffect(() => {
    let cancelled = false;

    const fetchItemNames = async (
      items: LogResponse[],
    ): Promise<Record<string, string>> => {
      const uniqueByType = (type: "product" | "meal") => [
        ...new Set(
          items.filter((l) => l.item.type === type).map((l) => l.item.id),
        ),
      ];
      const productIds = uniqueByType("product");
      const mealIds = uniqueByType("meal");
      const entries = await Promise.all([
        ...productIds.map(async (id): Promise<[string, string]> => {
          try {
            const d = await getFoodDetail(id);
            return [d.id, d.name];
          } catch {
            return [id, "Unknown food"];
          }
        }),
        ...mealIds.map(async (id): Promise<[string, string]> => {
          try {
            const m = await getMeal(id);
            return [m.id, m.name];
          } catch {
            return [id, "Unknown meal"];
          }
        }),
      ]);
      return Object.fromEntries(entries);
    };

    const load = async () => {
      setLoading(true);
      setError("");
      try {
        const [logRes, summaryRes] = await Promise.all([
          listLogs(dateStr, dateStr),
          getSummary(dateStr, dateStr, SUMMARY_CODES),
        ]);
        const nameMap = await fetchItemNames(logRes.items);
        if (cancelled) return;
        setLogs(logRes.items);
        setSummary(summaryRes.totals);
        setFoodNames(nameMap);
      } catch (err: unknown) {
        if (cancelled) return;
        setError(err instanceof Error ? err.message : "Failed to load diary");
      } finally {
        if (!cancelled) setLoading(false);
      }
    };

    load();

    return () => {
      cancelled = true;
    };
  }, [dateStr]);

  const goPrev = () => {
    const prev = new Date(currentDate);
    prev.setDate(prev.getDate() - 1);
    setCurrentDate(prev);
  };

  const goNext = () => {
    const next = new Date(currentDate);
    next.setDate(next.getDate() + 1);
    if (formatDate(next) <= todayString()) setCurrentDate(next);
  };

  const isToday = dateStr === todayString();
  const kcal = getNutrientVal(summary, "ENERGY_KCAL");
  const protein = getNutrientVal(summary, "PROTEIN_G");
  const carbs = getNutrientVal(summary, "CARBS_G");
  const fat = getNutrientVal(summary, "FAT_G");

  const mealSlotLogs = MEAL_SLOTS.map((slot) => ({
    ...slot,
    items: logs.filter((l) => l.meal_slot === slot.value),
  }));
  const otherLogs = logs.filter((l) => !l.meal_slot);

  const slotCalories = (slot: string) =>
    logs
      .filter((l) => l.meal_slot === slot)
      .reduce((s, l) => s + getCalories(l.nutrients), 0);

  const toggleMacroMode = () =>
    setMacroMode((c) => (c === "grams" ? "percent" : "grams"));

  const renderLogRow = (log: LogResponse) => (
    <UnstyledButton
      key={log.id}
      onClick={() => navigate(`/logs/${log.id}`, { state: { editing: true } })}
      p="sm"
      style={{ borderBottom: "1px solid var(--mantine-color-default-border)" }}
    >
      <Group gap="xs" align="center" wrap="nowrap">
        <Text fw={500} truncate style={{ flex: 1 }}>
          {foodNames[log.item.id] ?? "Loading..."}
        </Text>
        <Text c="dimmed" size="sm" fw={500} style={{ whiteSpace: "nowrap" }}>
          {log.quantity.amount} {log.quantity.unit}
        </Text>
        <Text
          c="dimmed"
          size="sm"
          fw={500}
          ta="right"
          miw={64}
          style={{ whiteSpace: "nowrap" }}
        >
          {Math.round(getCalories(log.nutrients))} kcal
        </Text>
      </Group>
    </UnstyledButton>
  );

  return (
    <Container p="md">
      <Group component="header" justify="space-between" mb="md">
        <Title order={1}>CalCo</Title>
        <Group gap="xs">
          <ActionIcon
            variant="subtle"
            onClick={() => setDarkMode((d) => !d)}
            aria-label="Toggle dark mode"
          >
            {darkMode ? <Sun size={20} /> : <Moon size={20} />}
          </ActionIcon>
          <Menu position="bottom-end">
            <Menu.Target>
              <Button variant="outline" aria-label="Open profile menu">
                <Group gap="xs">
                  <Avatar size="sm" color="blue">
                    {getInitials(displayName)}
                  </Avatar>
                  <Text c="dimmed" size="sm" fw={500} truncate maw={144}>
                    {displayName}
                  </Text>
                </Group>
              </Button>
            </Menu.Target>
            <Menu.Dropdown>
              <Menu.Item onClick={() => navigate("/meals")}>My Meals</Menu.Item>
              <Menu.Item color="red" onClick={() => logout()}>
                Logout
              </Menu.Item>
            </Menu.Dropdown>
          </Menu>
        </Group>
      </Group>

      {error && <ErrorBanner message={error} />}

      <Paper p="md" mb="md">
        <Stack gap="md">
          <Group justify="space-between" align="center">
            <ActionIcon
              variant="subtle"
              onClick={goPrev}
              aria-label="Previous day"
            >
              ←
            </ActionIcon>
            <Text fw={600} ta="center" truncate>
              {displayDate(currentDate)}
            </Text>
            <ActionIcon
              variant="subtle"
              onClick={goNext}
              disabled={isToday}
              aria-label="Next day"
            >
              →
            </ActionIcon>
          </Group>

          <SimpleGrid cols={{ base: 2, sm: 4 }}>
            <NutrientRing
              label="Calories"
              value={kcal?.amount ?? 0}
              unit={kcal?.unit ?? "kcal"}
              max={DEFAULT_CALORIE_GOAL}
              color={MACRO_COLORS.calories}
            />
            <NutrientRing
              label="Protein"
              value={protein?.amount ?? 0}
              unit={protein?.unit ?? "g"}
              max={150}
              color={MACRO_COLORS.protein}
            />
            <NutrientRing
              label="Carbs"
              value={carbs?.amount ?? 0}
              unit={carbs?.unit ?? "g"}
              max={250}
              color={MACRO_COLORS.carbs}
            />
            <NutrientRing
              label="Fat"
              value={fat?.amount ?? 0}
              unit={fat?.unit ?? "g"}
              max={65}
              color={MACRO_COLORS.fat}
            />
          </SimpleGrid>
          <Box ref={ringScrollRef} style={{ display: "none" }} />
        </Stack>
      </Paper>

      <Stack gap="sm">
        {loading && (
          <Stack gap="sm">
            <Skeleton height={16} width="80%" />
            <Skeleton height={16} width="60%" />
            <Skeleton height={16} width="100%" />
          </Stack>
        )}

        {!loading && logs.length === 0 && !error && (
          <EmptyState>No food logged for this day.</EmptyState>
        )}

        {!loading &&
          mealSlotLogs.map(({ value, label, items }) => (
            <Paper key={value} p={0} style={{ overflow: "hidden" }}>
              <Group p="md" gap="sm" align="center">
                <Stack gap={2} miw={0} style={{ flex: 1 }}>
                  <Text fw={600}>{label}</Text>
                  <SlotMacroSummary
                    logs={items}
                    mode={macroMode}
                    onToggle={toggleMacroMode}
                  />
                </Stack>
                <Text
                  c="dimmed"
                  size="sm"
                  fw={600}
                  style={{ whiteSpace: "nowrap" }}
                >
                  {Math.round(slotCalories(value))} kcal
                </Text>
              </Group>
              {items.length === 0 ? (
                <Text p="md" c="dimmed" ta="center">
                  No items
                </Text>
              ) : (
                items.map(renderLogRow)
              )}
              <Button
                variant="subtle"
                fullWidth
                onClick={() =>
                  navigate("/search", { state: { mealSlot: value } })
                }
                style={{
                  borderTop: "1px solid var(--mantine-color-default-border)",
                }}
              >
                Add Food
              </Button>
            </Paper>
          ))}

        {!loading && otherLogs.length > 0 && (
          <Paper p={0} style={{ overflow: "hidden" }}>
            <Group p="md" gap="sm" align="center">
              <Stack gap={2} miw={0} style={{ flex: 1 }}>
                <Text fw={600}>Other</Text>
                <SlotMacroSummary
                  logs={otherLogs}
                  mode={macroMode}
                  onToggle={toggleMacroMode}
                />
              </Stack>
              <Text
                c="dimmed"
                size="sm"
                fw={600}
                style={{ whiteSpace: "nowrap" }}
              >
                {Math.round(slotCalories(""))} kcal
              </Text>
            </Group>
            {otherLogs.map(renderLogRow)}
          </Paper>
        )}
      </Stack>
    </Container>
  );
}
