import { Container } from "@mantine/core";
import { useEffect, useState } from "react";
import { useNavigate } from "react-router-dom";
import { CustomFoodForm } from "@/components/CustomFoodForm";
import { ErrorBanner } from "@/components/ErrorBanner";
import { PageHeader } from "@/components/PageHeader";
import type { NutrientItem, UnitItem } from "../api/foods";
import { createCustomFood, listNutrients, listUnits } from "../api/foods";

export function CustomFoodCreate() {
  const navigate = useNavigate();
  const [nutrients, setNutrients] = useState<NutrientItem[]>([]);
  const [units, setUnits] = useState<UnitItem[]>([]);
  const [error, setError] = useState("");

  useEffect(() => {
    let cancelled = false;
    Promise.allSettled([listNutrients(), listUnits()]).then((results) => {
      if (cancelled) return;
      const [nRes, uRes] = results;
      const failures: string[] = [];
      if (nRes.status === "fulfilled") setNutrients(nRes.value.items);
      else failures.push("nutrients");
      if (uRes.status === "fulfilled") setUnits(uRes.value.items);
      else failures.push("units");
      if (failures.length > 0)
        setError(`Failed to load ${failures.join(" and ")}`);
    });
    return () => {
      cancelled = true;
    };
  }, []);

  return (
    <Container p="md">
      <PageHeader
        title="Create Custom Food"
        onBack={() => navigate("/home")}
        backLabel="Back to Diary"
      />

      {error && <ErrorBanner message={error} />}

      <CustomFoodForm
        idPrefix="cf"
        submitLabel="Create Food"
        submitPendingLabel="Creating..."
        failureMessage="Failed to create food"
        nutrients={nutrients}
        units={units}
        onSubmit={async (payload) => {
          const res = await createCustomFood(payload);
          navigate(`/foods/${res.id}`, { replace: true });
        }}
      />
    </Container>
  );
}
