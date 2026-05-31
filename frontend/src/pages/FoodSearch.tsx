import { useState, useEffect, useRef } from "react";
import { useLocation, useNavigate } from "react-router-dom";
import { searchFoods } from "../api/foods";
import type { SearchResult } from "../api/foods";
import { Card } from "@/components/ui/card";
import { Button } from "@/components/ui/button";
import { Skeleton } from "@/components/ui/skeleton";
import { ErrorBanner } from "@/components/ErrorBanner";
import { PageHeader } from "@/components/PageHeader";
import { EmptyState } from "@/components/EmptyState";
import { SearchQueryInput } from "@/components/SearchQueryInput";
import { FoodSearchResultRow } from "@/components/FoodSearchResultRow";

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

    debounceRef.current = setTimeout(async () => {
      try {
        const res = await searchFoods(trimmed);
        setResults(res.items);
      } catch (err: unknown) {
        setError(err instanceof Error ? err.message : "Search failed");
        setResults([]);
      } finally {
        setLoading(false);
      }
    }, 300);

    return () => {
      if (debounceRef.current) clearTimeout(debounceRef.current);
    };
  }, [query]);

  return (
    <div className="page">
      <PageHeader title="Search Foods" onBack={() => navigate("/home")} backLabel="Back to Diary" />

      <div className="mb-3">
        <SearchQueryInput
          placeholder="Search for a food..."
          value={query}
          onChange={setQuery}
          autoFocus
        />
      </div>

      {error && <ErrorBanner message={error} />}

      {loading && (
        <Card className="overflow-hidden p-0">
          {[1, 2, 3].map((i) => (
            <div key={i} className="border-b border-border px-3 py-2 last:border-b-0">
              <div className="flex items-center justify-between gap-3">
                <div className="min-w-0 flex-1 space-y-1.5">
                  <Skeleton className="h-4 w-4/5" />
                  <Skeleton className="h-3 w-3/5" />
                </div>
                <Skeleton className="h-9 w-28" />
              </div>
            </div>
          ))}
        </Card>
      )}

      {!loading && !error && query.trim() && results.length === 0 && (
        <EmptyState>
          <p>No foods found. Try a different search.</p>
          <Button onClick={goCreateCustomFood}>Create Custom Food</Button>
        </EmptyState>
      )}

      {!loading && !error && results.length > 0 && (
        <Card className="overflow-hidden p-0">
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
        </Card>
      )}

      {!query.trim() && (
        <EmptyState>
          <p>Search for a food to get started.</p>
          <Button onClick={goCreateCustomFood}>Create Custom Food</Button>
        </EmptyState>
      )}
    </div>
  );
}
