# Fix: Select.Item empty string value

Radix UI's `Select.Item` throws `Uncaught Error: A <Select.Item /> must have a value prop that is not an empty string` when value is `""`.

## Changes needed

### File: `frontend/src/pages/FoodLogDetail.tsx`

1. **Line 209** — State init:
   ```ts
   // Before:
   const [editSlot, setEditSlot] = useState("");
   // After:
   const [editSlot, setEditSlot] = useState("__none__");
   ```

2. **Line 221** — Load data:
   ```ts
   // Before:
   setEditSlot(logRes.meal_slot ?? "");
   // After:
   setEditSlot(logRes.meal_slot ?? "__none__");
   ```

3. **Line 248** — Save logic:
   ```ts
   // Before:
   meal_slot: editSlot || null,
   // After:
   meal_slot: editSlot === "__none__" ? null : editSlot,
   ```

4. **Line 379** — SelectItem value:
   ```tsx
   // Before:
   <SelectItem value="">None</SelectItem>
   // After:
   <SelectItem value="__none__">None</SelectItem>
   ```

### File: `frontend/src/pages/FoodDetail.tsx`

1. **Lines 44-46** — State init:
   ```ts
   // Before:
   const [logSlot, setLogSlot] = useState(
     (location.state as { mealSlot?: string } | null)?.mealSlot ?? "",
   );
   // After:
   const [logSlot, setLogSlot] = useState(
     (location.state as { mealSlot?: string } | null)?.mealSlot ?? "__none__",
   );
   ```

2. **Line 72** — Save logic:
   ```ts
   // Before:
   meal_slot: logSlot || undefined,
   // After:
   meal_slot: logSlot === "__none__" ? undefined : logSlot,
   ```

3. **Line 249** — SelectItem value:
   ```tsx
   // Before:
   <SelectItem value="">No meal slot</SelectItem>
   // After:
   <SelectItem value="__none__">No meal slot</SelectItem>
   ```

## Verification

Run `cd frontend && pnpm exec playwright test` to verify E2E tests pass.
