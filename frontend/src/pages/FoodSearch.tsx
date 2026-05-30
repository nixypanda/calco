import { useState, useEffect, useRef } from "react";
import { useLocation, useNavigate } from "react-router-dom";
import { searchFoods } from "../api/foods";
import type { SearchResult } from "../api/foods";
import { Card } from "@/components/ui/card";
import { Input } from "@/components/ui/input";
import { Button } from "@/components/ui/button";
import { Skeleton } from "@/components/ui/skeleton";
import { Badge } from "@/components/ui/badge";
import { ErrorBanner } from "@/components/ErrorBanner";
import { PageHeader } from "@/components/PageHeader";
import { EmptyState } from "@/components/EmptyState";

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
        <Input
          type="text"
          placeholder="Search for a food..."
          value={query}
          onChange={(e) => setQuery(e.target.value)}
          autoFocus
        />
      </div>

      {error && <ErrorBanner message={error} />}

      {loading && (
        <div className="flex flex-col gap-3">
          {[1, 2, 3].map((i) => (
            <Card key={i} className="flex flex-col gap-2 p-4">
              <Skeleton className="h-4 w-3/5" />
              <Skeleton className="h-4 w-2/5" />
            </Card>
          ))}
        </div>
      )}

      {!loading && !error && query.trim() && results.length === 0 && (
        <EmptyState>
          <p>No foods found. Try a different search.</p>
          <Button onClick={goCreateCustomFood}>Create Custom Food</Button>
        </EmptyState>
      )}

      {!loading && !error && results.length > 0 && (
        <div className="flex flex-col gap-3">
          {results.map((item) => (
            <Card
              key={item.id}
              className="flex items-center justify-between p-4 cursor-pointer hover:bg-muted/50"
              onClick={() =>
                navigate(`/foods/${item.id}`, {
                  state: mealSlot ? { mealSlot } : undefined,
                })
              }
            >
              <div className="flex flex-col gap-0.5 min-w-0">
                <span className="font-bold truncate">{item.name}</span>
                {item.brand && (
                  <span className="text-muted-foreground text-sm">{item.brand}</span>
                )}
              </div>
              <div className="flex items-center flex-wrap gap-1.5">
                {item.category && <Badge variant="secondary">{item.category}</Badge>}
                {item.source === "USER" && <Badge variant="outline">Custom</Badge>}
              </div>
            </Card>
          ))}
        </div>
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
