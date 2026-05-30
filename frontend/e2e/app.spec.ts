import { test, expect } from "@playwright/test";

test("app renders an entry screen", async ({ page }) => {
  await page.goto("/");
  await expect(page.locator("h1").first()).toHaveText(
    /CalCo|Admin Dashboard/,
  );
});
