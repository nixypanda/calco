import { test, expect } from "@playwright/test";

test("app renders heading and status", async ({ page }) => {
  await page.goto("/");
  await expect(page.locator("h1")).toHaveText("CalCo");
  await expect(page.locator(".status")).toHaveText("Frontend running ✓");
});
