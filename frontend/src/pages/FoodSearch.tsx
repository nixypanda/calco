import { useState, useEffect, useRef } from "react";
import { useLocation, useNavigate } from "react-router-dom";
import { searchFoods } from "../api/foods";
import type { SearchResult } from "../api/foods";
import { Card } from "@/components/ui/card";
import { Input } from "@/components/ui/input";
import { Button } from "@/components/ui/button";
import { Badge } from "@/components/ui/badge";

export function FoodSearch() {
  const navigate = useNavigate();
  const location = useLocation();
  const mealSlot = (location.state as { mealSlot?: string } | null)?.mealSlot;
  const [query, setQuery] = useState("");
  const [results, setResults] = useState<SearchResult[]>([]);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState("");
  const debounceRef = useRef<ReturnType<typeof setTimeout> | null>(null);

  const goCreateCustomFood = () => {
    navigate("/foods/custom/new");
  };

  useEffect(() => {
    if (debounceRef.current) {
      clearTimeout(debounceRef.current);
    }

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
    <div className="catalog-page">
      <header>
        <div className="header-left">
          <button
            className="btn-back"
            onClick={() => navigate("/home")}
            aria-label="Back to Diary"
          >
            <span aria-hidden="true">‹</span>
          </button>
          <h1>Search Foods</h1>
        </div>
      </header>
      <main>
        <div className="search-bar">
          <Input
            type="text"
            placeholder="Search for a food..."
            value={query}
            onChange={(e) => setQuery(e.target.value)}
            autoFocus
          />
        </div>

        {error && <p className="error">{error}</p>}

        {loading && (
          <div className="search-results">
            {[1, 2, 3].map((i) => (
              <div key={i} className="search-result skeleton">
                <div className="skeleton-line w-60" />
                <div className="skeleton-line w-40" />
              </div>
            ))}
          </div>
        )}

        {!loading && !error && query.trim() && results.length === 0 && (
          <div className="empty-state">
            <p>No foods found. Try a different search.</p>
            <Button
              onClick={goCreateCustomFood}
            >
              Create Custom Food
            </Button>
          </div>
        )}

        {!loading && !error && results.length > 0 && (
          <div className="search-results">
            {results.map((item) => (
              <Card
                key={item.id}
                className="flex items-center justify-between w-full min-h-16 p-3.5 cursor-pointer hover:bg-muted/50"
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
                  {item.category && (
                    <Badge variant="secondary">{item.category}</Badge>
                  )}
                  {item.source === "USER" && (
                    <Badge variant="secondary" className="bg-green-100 text-green-800 hover:bg-green-100">Custom</Badge>
                  )}
                </div>
              </Card>
            ))}
          </div>
        )}

        {!query.trim() && (
          <div className="empty-state">
            <p>Search for a food to get started.</p>
            <Button
              onClick={goCreateCustomFood}
            >
              Create Custom Food
            </Button>
          </div>
        )}
      </main>
    </div>
  );
}
