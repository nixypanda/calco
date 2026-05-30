import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table";

interface NutrientRow {
  code: string;
  amount: number | string;
  unit: string;
}

function formatAmount(value: number | string): string {
  const n = typeof value === "number" ? value : parseFloat(value);
  if (!isFinite(n)) return "-";
  return n.toFixed(1);
}

export function NutrientsTable({ nutrients }: { nutrients: NutrientRow[] }) {
  return (
    <Table>
      <TableHeader>
        <TableRow>
          <TableHead>Nutrient</TableHead>
          <TableHead className="text-right w-24">Amount</TableHead>
          <TableHead className="text-right w-24">Unit</TableHead>
        </TableRow>
      </TableHeader>
      <TableBody>
        {nutrients.map((n) => (
          <TableRow key={n.code}>
            <TableCell>{n.code.replace(/_/g, " ").toLowerCase()}</TableCell>
            <TableCell className="text-right">{formatAmount(n.amount)}</TableCell>
            <TableCell className="text-right">{n.unit || "-"}</TableCell>
          </TableRow>
        ))}
      </TableBody>
    </Table>
  );
}
