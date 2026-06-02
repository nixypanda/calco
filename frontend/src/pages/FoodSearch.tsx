import {
  Box,
  Button,
  Container,
  Group,
  Paper,
  Skeleton,
  Stack,
} from "@mantine/core";
import { useEffect, useRef, useState } from "react";
import { useLocation, useNavigate } from "react-router-dom";
import { EmptyState } from "@/components/EmptyState";
import { ErrorBanner } from "@/components/ErrorBanner";
import { FoodSearchResultRow } from "@/components/FoodSearchResultRow";
import { PageHeader } from "@/components/PageHeader";
import { SearchQueryInput } from "@/components/SearchQueryInput";
import type { SearchResult } from "../api/foods";
import { searchFoods } from "../api/foods";

export function FoodSearch() {
  const navigate = useNavigate();
  const location = useLocation();
  const mealSlot = (location.state as { mealSlot?: string } | null)?.mealSlot;
  const [query, setQuery] = useState("");
  const [results, setResults] = useState<SearchResult[]>([]);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState("");
  const debounceRef = useRef<ReturnType<typeof setTimeout> | null>(null);

  const goCreateCustomFood = () => navigate("/foods/custom/new");

  useEffect(() => {
    if (debounceRef.current) clearTimeout(debounceRef.current);

    const trimmed = query.trim();
    if (!trimmed) {
      setResults([]);
      setLoading(false);
      setError("");
      return;
    }

    setLoading(true);
    setError("");

    const controller = new AbortController();
    debounceRef.current = setTimeout(async () => {
      try {
        const res = await searchFoods(trimmed, { signal: controller.signal });
        if (controller.signal.aborted) return;
        setResults(res.items);
      } catch (err: unknown) {
        if (controller.signal.aborted) return;
        if (err instanceof DOMException && err.name === "AbortError") return;
        setError(err instanceof Error ? err.message : "Search failed");
        setResults([]);
      } finally {
        if (!controller.signal.aborted) setLoading(false);
      }
    }, 300);

    return () => {
      if (debounceRef.current) clearTimeout(debounceRef.current);
      controller.abort();
    };
  }, [query]);

  return (
    <Container p="md">
      <PageHeader
        title="Search Foods"
        onBack={() => navigate("/home")}
        backLabel="Back to Diary"
      />

      <Box mb="sm">
        <SearchQueryInput
          placeholder="Search for a food..."
          value={query}
          onChange={setQuery}
          autoFocus
        />
      </Box>

      {error && <ErrorBanner message={error} />}

      {loading && (
        <Paper p={0} style={{ overflow: "hidden" }}>
          {[1, 2, 3].map((i) => (
            <Box
              key={i}
              px="sm"
              py="xs"
              style={{
                borderBottom: "1px solid var(--mantine-color-default-border)",
              }}
            >
              <Group justify="space-between" gap="sm">
                <Stack gap={6} miw={0} style={{ flex: 1 }}>
                  <Skeleton height={16} width="80%" />
                  <Skeleton height={12} width="60%" />
                </Stack>
                <Skeleton height={36} width={112} />
              </Group>
            </Box>
          ))}
        </Paper>
      )}

      {!loading && !error && query.trim() && results.length === 0 && (
        <EmptyState>
          <Stack gap="sm" align="center">
            <p>No foods found. Try a different search.</p>
            <Button onClick={goCreateCustomFood}>Create Custom Food</Button>
          </Stack>
        </EmptyState>
      )}

      {!loading && !error && results.length > 0 && (
        <Paper p={0} style={{ overflow: "hidden" }}>
          {results.map((item) => (
            <FoodSearchResultRow
              key={item.id}
              item={item}
              showBarcode={Boolean(item.barcode && /^\d+$/.test(query.trim()))}
              onSelect={() =>
                navigate(`/foods/${item.id}`, {
                  state: mealSlot ? { mealSlot } : undefined,
                })
              }
            />
          ))}
        </Paper>
      )}

      {!query.trim() && (
        <EmptyState>
          <Stack gap="sm" align="center">
            <p>Search for a food to get started.</p>
            <Button onClick={goCreateCustomFood}>Create Custom Food</Button>
          </Stack>
        </EmptyState>
      )}
    </Container>
  );
}
