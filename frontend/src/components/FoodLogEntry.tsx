import {
  ActionIcon,
  Anchor,
  Badge,
  Button,
  Container,
  Group,
  NativeSelect,
  Paper,
  Stack,
  Text,
  TextInput,
  Title,
} from "@mantine/core";
import { Minus, Plus } from "lucide-react";
import { useMemo, useState } from "react";
import { Link } from "react-router-dom";
import type { ProductDetail, UnitItem } from "@/api/foods";
import type { NutrientSnapshotDto } from "@/api/logs";
import { ErrorBanner } from "@/components/ErrorBanner";
import { FieldRow } from "@/components/FieldRow";
import { MacroBreakdown } from "@/components/MacroBreakdown";
import { NutrientsTable } from "@/components/NutrientsTable";
import { PageHeader } from "@/components/PageHeader";
import { MEAL_SLOTS, scaleNutrients } from "@/lib/nutrition";
import { formatTimestamp } from "@/lib/time";

function formatStep(n: number): string {
  if (Number.isInteger(n)) return String(n);
  const fixed = n.toFixed(2);
  if (fixed.includes(".")) {
    const trimmed = fixed.replace(/0+$/, "").replace(/\.$/, "");
    if (trimmed && trimmed !== "-") return trimmed;
  }
  return fixed;
}

function NumberStepper({
  value,
  onChange,
  step = 1,
  min,
}: {
  value: string;
  onChange: (v: string) => void;
  step?: number;
  min?: number;
}) {
  const adjust = (delta: number) => {
    const n = parseFloat(value);
    const current = Number.isFinite(n) ? n : 0;
    let next = current + delta;
    if (min != null && next < min) next = min;
    onChange(formatStep(next));
  };
  return (
    <Group gap="xs" justify="flex-end" align="center">
      <ActionIcon
        variant="outline"
        radius="xl"
        onClick={() => adjust(-step)}
        aria-label="Decrement"
      >
        <Minus size={14} />
      </ActionIcon>
      <input
        type="text"
        inputMode="decimal"
        value={value}
        onChange={(e) => onChange(e.target.value)}
        style={{
          width: 64,
          textAlign: "center",
          fontWeight: 600,
          background: "transparent",
          border: 0,
          outline: "none",
        }}
      />
      <ActionIcon
        variant="outline"
        radius="xl"
        onClick={() => adjust(step)}
        aria-label="Increment"
      >
        <Plus size={14} />
      </ActionIcon>
    </Group>
  );
}

export interface LogValues {
  amount: string;
  unit: string;
  slot: string;
  notes: string;
}

export interface NutrientSnapshot {
  amount: string;
  unit: string;
  nutrients: NutrientSnapshotDto[];
}

interface Props {
  title: string;
  itemName: string;
  food: ProductDetail | null;
  snapshot?: NutrientSnapshot;
  units: UnitItem[];
  initial: LogValues;
  loggedAt?: string;
  brand?: string | null;
  categories?: string[];
  servingSizeG?: string | null;
  customFoodEditPath?: string;
  submitLabel: string;
  submittingLabel: string;
  onSubmit: (values: LogValues) => Promise<void>;
  onDelete?: () => Promise<void>;
  onBack: () => void;
  backLabel: string;
}

export function FoodLogEntry({
  title,
  itemName,
  food,
  snapshot,
  units,
  initial,
  loggedAt,
  brand,
  categories = [],
  servingSizeG,
  customFoodEditPath,
  submitLabel,
  submittingLabel,
  onSubmit,
  onDelete,
  onBack,
  backLabel,
}: Props) {
  const [values, setValues] = useState<LogValues>(initial);
  const [submitting, setSubmitting] = useState(false);
  const [deleting, setDeleting] = useState(false);
  const [error, setError] = useState("");

  const computedNutrients = useMemo(() => {
    const parsed = parseFloat(values.amount);
    const amount = Number.isFinite(parsed) && parsed >= 0 ? parsed : 0;

    if (snapshot && snapshot.unit === values.unit) {
      const base = parseFloat(snapshot.amount) || 0;
      if (base > 0) {
        const factor = amount / base;
        return snapshot.nutrients.map((n) => ({
          code: n.code,
          amount: (parseFloat(n.amount) || 0) * factor,
          unit: n.unit,
        }));
      }
    }

    if (food?.nutrients && food.nutrients.length > 0) {
      return scaleNutrients(
        food.nutrients,
        amount,
        values.unit,
        food.servings ?? [],
      );
    }

    return (snapshot?.nutrients ?? []).map((n) => ({
      code: n.code,
      amount: parseFloat(n.amount) || 0,
      unit: n.unit,
    }));
  }, [food, snapshot, values.amount, values.unit]);

  const unitOptions = useMemo(() => {
    const source: UnitItem[] = food?.allowed_units ?? units;
    if (!values.unit || source.some((u) => u.code === values.unit)) {
      return source;
    }
    return [{ code: values.unit, name: values.unit, kind: "" }, ...source];
  }, [units, values.unit, food]);

  const handleSubmit = async () => {
    setSubmitting(true);
    setError("");
    try {
      await onSubmit(values);
    } catch (e: unknown) {
      setError(e instanceof Error ? e.message : "Failed to save");
    } finally {
      setSubmitting(false);
    }
  };

  const handleDelete = async () => {
    if (!onDelete) return;
    if (!window.confirm("Delete this log? This cannot be undone.")) return;
    setDeleting(true);
    setError("");
    try {
      await onDelete();
    } catch (e: unknown) {
      setError(e instanceof Error ? e.message : "Failed to delete");
    } finally {
      setDeleting(false);
    }
  };

  const subtitleParts = [
    brand,
    servingSizeG ? `Serving ${servingSizeG}g` : null,
    loggedAt ? formatTimestamp(loggedAt) : null,
  ].filter(Boolean) as string[];

  return (
    <Container p="md">
      <PageHeader title={title} onBack={onBack} backLabel={backLabel} />

      <Stack gap="xs" mb="lg">
        <Title order={2}>{itemName}</Title>
        {(subtitleParts.length > 0 || customFoodEditPath) && (
          <Group gap="xs" align="center" wrap="wrap">
            {subtitleParts.length > 0 && (
              <Text c="dimmed" size="sm">
                {subtitleParts.join(" · ")}
              </Text>
            )}
            {categories.map((category) => (
              <Badge key={category} variant="light" color="gray">
                {category}
              </Badge>
            ))}
            {customFoodEditPath && (
              <Anchor component={Link} to={customFoodEditPath} size="sm">
                Edit food
              </Anchor>
            )}
          </Group>
        )}
      </Stack>

      {error && <ErrorBanner message={error} />}

      <Paper p={0} mb="lg" style={{ overflow: "hidden" }}>
        <FieldRow label="Meal">
          <NativeSelect
            aria-label="Meal slot"
            value={values.slot}
            onChange={(e) =>
              setValues((prev) => ({ ...prev, slot: e.target.value }))
            }
            data={[
              { value: "__none__", label: "None" },
              ...MEAL_SLOTS.map((s) => ({ value: s.value, label: s.label })),
            ]}
          />
        </FieldRow>
        <FieldRow label="Amount">
          <NumberStepper
            value={values.amount}
            onChange={(v) => setValues((prev) => ({ ...prev, amount: v }))}
            min={0}
          />
        </FieldRow>
        <FieldRow label="Unit">
          <NativeSelect
            aria-label="Unit"
            value={values.unit}
            onChange={(e) =>
              setValues((prev) => ({ ...prev, unit: e.target.value }))
            }
            data={unitOptions.map((u) => ({
              value: u.code,
              label: u.name === u.code ? u.code : `${u.name} (${u.code})`,
            }))}
          />
        </FieldRow>
        <FieldRow label="Notes">
          <TextInput
            type="text"
            value={values.notes}
            placeholder="Optional notes"
            onChange={(e) =>
              setValues((v) => ({ ...v, notes: e.target.value }))
            }
          />
        </FieldRow>
        <Group
          gap="xs"
          p="md"
          wrap="wrap"
          style={{ borderTop: "1px solid var(--mantine-color-default-border)" }}
        >
          <Button onClick={handleSubmit} disabled={submitting || deleting}>
            {submitting ? submittingLabel : submitLabel}
          </Button>
          {onDelete && (
            <Button
              color="red"
              onClick={handleDelete}
              disabled={submitting || deleting}
            >
              {deleting ? "Deleting..." : "Delete"}
            </Button>
          )}
        </Group>
      </Paper>

      <Stack gap="lg">
        <Stack gap="sm">
          <Title order={2}>Macro Breakdown</Title>
          <MacroBreakdown
            nutrients={computedNutrients.map((n) => ({
              code: n.code,
              amount: n.amount,
            }))}
          />
        </Stack>

        <Stack gap="sm">
          <Title order={2}>Nutrients</Title>
          <NutrientsTable nutrients={computedNutrients} />
        </Stack>
      </Stack>
    </Container>
  );
}
