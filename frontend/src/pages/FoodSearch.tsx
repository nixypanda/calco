import { useState, useEffect, useRef } from "react";
import { useNavigate } from "react-router-dom";
import { searchFoods } from "../api/foods";
import type { SearchResult } from "../api/foods";

export function FoodSearch() {
  const navigate = useNavigate();
  const [query, setQuery] = useState("");
  const [results, setResults] = useState<SearchResult[]>([]);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState("");
  const debounceRef = useRef<ReturnType<typeof setTimeout> | null>(null);

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
        <h1>Search Foods</h1>
        <button onClick={() => navigate("/home")}>Back to Diary</button>
      </header>
      <main>
        <div className="search-bar">
          <input
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
          <p className="empty-state">No foods found. Try a different search.</p>
        )}

        {!loading && !error && results.length > 0 && (
          <div className="search-results">
            {results.map((item) => (
              <button
                key={item.id}
                className="search-result"
                onClick={() => navigate(`/foods/${item.id}`)}
              >
                <div className="search-result-main">
                  <span className="search-result-name">{item.name}</span>
                  {item.brand && (
                    <span className="search-result-brand">{item.brand}</span>
                  )}
                </div>
                <div className="search-result-meta">
                  {item.category && (
                    <span className="category-chip">{item.category}</span>
                  )}
                  {item.source === "USER" && (
                    <span className="source-chip">Custom</span>
                  )}
                </div>
              </button>
            ))}
          </div>
        )}

        {!query.trim() && (
          <p className="empty-state">Search for a food to get started.</p>
        )}
      </main>
    </div>
  );
}
