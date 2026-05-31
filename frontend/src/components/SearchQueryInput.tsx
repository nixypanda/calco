import { useEffect, useMemo, useRef, useState } from "react";
import { listCategorySuggestions } from "../api/foods";
import type { CategorySuggestion } from "../api/foods";
import { Input } from "@/components/ui/input";
import { cn } from "@/lib/utils";

interface SearchQueryInputProps {
  value: string;
  onChange: (value: string) => void;
  placeholder?: string;
  autoFocus?: boolean;
  className?: string;
}

interface TokenInfo {
  start: number;
  end: number;
  value: string;
}

type Completion =
  | { type: "operator"; label: string; replacement: string }
  | { type: "category"; label: string; replacement: string; count: number };

function tokenAt(value: string, cursor: number): TokenInfo {
  let start = 0;
  let inQuotes = false;
  for (let i = 0; i < cursor; i += 1) {
    const ch = value[i];
    if (ch === '"') inQuotes = !inQuotes;
    if (/\s/.test(ch) && !inQuotes) start = i + 1;
  }

  let end = value.length;
  inQuotes = false;
  for (let i = start; i < value.length; i += 1) {
    const ch = value[i];
    if (ch === '"') inQuotes = !inQuotes;
    if (i >= cursor && /\s/.test(ch) && !inQuotes) {
      end = i;
      break;
    }
  }

  return { start, end, value: value.slice(start, end) };
}

function stripCategoryValue(value: string): string {
  return value.trim().replace(/^"/, "").replace(/"$/, "");
}

function quoteCategory(value: string): string {
  return /\s/.test(value) ? `"${value}"` : value;
}

function replaceToken(query: string, token: TokenInfo, replacement: string): string {
  const next = `${query.slice(0, token.start)}${replacement}${query.slice(token.end)}`;
  return next;
}

function categoryPrefix(token: string): string | null {
  if (token.startsWith("category:")) return "category:";
  if (token.startsWith("-category:")) return "-category:";
  return null;
}

export function SearchQueryInput({
  value,
  onChange,
  placeholder,
  autoFocus,
  className,
}: SearchQueryInputProps) {
  const inputRef = useRef<HTMLInputElement | null>(null);
  const [cursor, setCursor] = useState(0);
  const [categories, setCategories] = useState<CategorySuggestion[]>([]);

  const token = useMemo(() => tokenAt(value, cursor), [value, cursor]);
  const prefix = categoryPrefix(token.value);
  const categoryQuery = prefix
    ? stripCategoryValue(token.value.slice(prefix.length))
    : "";

  useEffect(() => {
    let cancelled = false;
    if (!prefix) {
      setCategories([]);
      return;
    }

    listCategorySuggestions(categoryQuery, 8)
      .then((res) => {
        if (!cancelled) setCategories(res.items);
      })
      .catch(() => {
        if (!cancelled) setCategories([]);
      });

    return () => {
      cancelled = true;
    };
  }, [categoryQuery, prefix]);

  const completions = useMemo<Completion[]>(() => {
    const current = token.value.toLowerCase();
    if (!current) return [];

    if (!current.includes(":")) {
      const operators: Completion[] = [];
      if ("category:".startsWith(current)) {
        operators.push({
          type: "operator",
          label: "category:",
          replacement: "category:",
        });
      }
      if ("-category:".startsWith(current)) {
        operators.push({
          type: "operator",
          label: "-category:",
          replacement: "-category:",
        });
      }
      return operators;
    }

    if (!prefix) return [];
    return categories.map((category) => ({
      type: "category",
      label: category.value,
      replacement: `${prefix}${quoteCategory(category.value)}`,
      count: category.count,
    }));
  }, [categories, prefix, token.value]);

  const applyCompletion = (completion: Completion) => {
    const next = replaceToken(value, token, completion.replacement);
    onChange(next);
    const nextCursor = token.start + completion.replacement.length;
    requestAnimationFrame(() => {
      inputRef.current?.setSelectionRange(nextCursor, nextCursor);
      inputRef.current?.focus();
    });
  };

  return (
    <div className={cn("flex flex-col gap-1", className)}>
      <Input
        ref={inputRef}
        type="text"
        placeholder={placeholder}
        value={value}
        onChange={(e) => {
          onChange(e.target.value);
          setCursor(e.target.selectionStart ?? e.target.value.length);
        }}
        onClick={(e) => setCursor(e.currentTarget.selectionStart ?? value.length)}
        onKeyUp={(e) => setCursor(e.currentTarget.selectionStart ?? value.length)}
        onKeyDown={(e) => {
          setCursor(e.currentTarget.selectionStart ?? value.length);
          if (e.key === "Tab" && completions[0]) {
            e.preventDefault();
            applyCompletion(completions[0]);
          }
        }}
        autoFocus={autoFocus}
      />

      {completions.length > 0 && (
        <div className="glass max-h-56 overflow-y-auto rounded-3xl p-1.5">
          {completions.map((completion) => (
            <button
              key={`${completion.type}:${completion.replacement}`}
              type="button"
              className="flex w-full items-center justify-between gap-3 rounded-2xl px-3.5 py-2.5 text-left text-sm transition-colors hover:bg-white/55 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring/50 dark:hover:bg-white/[0.08]"
              onMouseDown={(e) => e.preventDefault()}
              onClick={() => applyCompletion(completion)}
            >
              <span className="font-medium">{completion.label}</span>
              {completion.type === "category" && (
                <span className="rounded-full bg-white/55 px-2 py-0.5 text-xs font-medium text-muted-foreground dark:bg-white/[0.08]">
                  {completion.count}
                </span>
              )}
            </button>
          ))}
        </div>
      )}
    </div>
  );
}
