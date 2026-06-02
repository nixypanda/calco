import { useEffect, useMemo, useRef, useState } from "react";
import { listCategorySuggestions } from "../api/foods";
import type { CategorySuggestion } from "../api/foods";
import {
  TextInput,
  Paper,
  Stack,
  UnstyledButton,
  Group,
  Text,
  Badge,
} from "@mantine/core";

interface SearchQueryInputProps {
  value: string;
  onChange: (value: string) => void;
  placeholder?: string;
  autoFocus?: boolean;
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

function replaceToken(
  query: string,
  token: TokenInfo,
  replacement: string,
): string {
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
    if (!prefix) {
      setCategories([]);
      return;
    }
    const controller = new AbortController();
    const timer = setTimeout(() => {
      listCategorySuggestions(categoryQuery, 8, { signal: controller.signal })
        .then((res) => {
          if (!controller.signal.aborted) setCategories(res.items);
        })
        .catch((err: unknown) => {
          if (controller.signal.aborted) return;
          if (err instanceof DOMException && err.name === "AbortError") return;
          setCategories([]);
        });
    }, 250);

    return () => {
      clearTimeout(timer);
      controller.abort();
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
    <Stack gap={4}>
      <TextInput
        ref={inputRef}
        type="text"
        placeholder={placeholder}
        value={value}
        onChange={(e) => {
          onChange(e.target.value);
          setCursor(e.target.selectionStart ?? e.target.value.length);
        }}
        onClick={(e) =>
          setCursor(e.currentTarget.selectionStart ?? value.length)
        }
        onKeyUp={(e) =>
          setCursor(e.currentTarget.selectionStart ?? value.length)
        }
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
        <Paper p={4} mah={224} style={{ overflowY: "auto" }} withBorder>
          <Stack gap={2}>
            {completions.map((completion) => (
              <UnstyledButton
                key={`${completion.type}:${completion.replacement}`}
                onMouseDown={(e) => e.preventDefault()}
                onClick={() => applyCompletion(completion)}
                px="sm"
                py="xs"
              >
                <Group justify="space-between" gap="sm">
                  <Text size="sm" fw={500}>
                    {completion.label}
                  </Text>
                  {completion.type === "category" && (
                    <Badge size="xs" variant="light" color="gray">
                      {completion.count}
                    </Badge>
                  )}
                </Group>
              </UnstyledButton>
            ))}
          </Stack>
        </Paper>
      )}
    </Stack>
  );
}
