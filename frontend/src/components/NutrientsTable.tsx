import { Table } from "@mantine/core";

interface NutrientRow {
  code: string;
  amount: number | string;
  unit: string;
}

function formatAmount(value: number | string): string {
  const n = typeof value === "number" ? value : parseFloat(value);
  if (!Number.isFinite(n)) return "-";
  return n.toFixed(1);
}

export function NutrientsTable({ nutrients }: { nutrients: NutrientRow[] }) {
  return (
    <Table>
      <Table.Thead>
        <Table.Tr>
          <Table.Th>Nutrient</Table.Th>
          <Table.Th ta="right" w={96}>
            Amount
          </Table.Th>
          <Table.Th ta="right" w={96}>
            Unit
          </Table.Th>
        </Table.Tr>
      </Table.Thead>
      <Table.Tbody>
        {nutrients.map((n) => (
          <Table.Tr key={n.code}>
            <Table.Td>{n.code.replace(/_/g, " ").toLowerCase()}</Table.Td>
            <Table.Td ta="right">{formatAmount(n.amount)}</Table.Td>
            <Table.Td ta="right">{n.unit || "-"}</Table.Td>
          </Table.Tr>
        ))}
      </Table.Tbody>
    </Table>
  );
}
