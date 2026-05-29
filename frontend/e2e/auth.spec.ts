import { test, expect } from "@playwright/test";

test.describe("Auth flow", () => {
  test("first-run bootstrap, admin CRUD, login as user", async ({ page }) => {
    // 1. Visit app — should show bootstrap setup (no admin exists)
    await page.goto("/");
    await expect(page.getByText("First-Time Setup")).toBeVisible();
    await expect(page.getByText("Create the admin account")).toBeVisible();

    // 2. Create bootstrap admin
    await page.getByRole("textbox").first().fill("admin");
    await page.getByLabel("Password").fill("adminpass123");
    await page.getByRole("button", { name: "Create Admin" }).click();

    // 3. Should redirect to admin dashboard
    await expect(page.getByText("Admin Dashboard")).toBeVisible({ timeout: 5000 });
    await expect(page.getByText("No users yet.")).toBeVisible();

    // 4. Create a normal user
    await page.getByRole("button", { name: "Create User" }).click();
    await page.getByPlaceholder("Username").fill("alice");
    await page.getByPlaceholder("Display Name").fill("Alice");
    await page.getByPlaceholder("Initial Password").fill("alicepass123");
    await page.getByRole("button", { name: "Save" }).click();

    // 5. Verify user appears in list (use cell locator to be specific)
    await expect(page.getByRole("cell", { name: "alice", exact: true })).toBeVisible();
    await expect(page.getByRole("cell", { name: "active", exact: true })).toBeVisible();

    // 6. Logout via header button
    await page.getByRole("button", { name: "Logout" }).click();

    // 7. Should be on login page
    await expect(page.getByRole("heading", { name: "Log In" })).toBeVisible();

    // 8. Login as the created user
    await page.getByRole("textbox").first().fill("alice");
    await page.getByLabel("Password").fill("alicepass123");
    await page.getByRole("button", { name: "Log In" }).click();

    // 9. Should see user home
    await expect(page.getByText("Welcome,")).toBeVisible({ timeout: 5000 });
    await expect(page.getByText("Alice")).toBeVisible();
    await expect(page.getByText("Your food diary will appear here.")).toBeVisible();

    // 10. Try navigating to /admin as user — should redirect away
    await page.goto("/admin");
    await expect(page.getByText("Your food diary will appear here.")).toBeVisible({ timeout: 5000 });

    // 11. Logout as user
    await page.getByRole("button", { name: "Logout" }).click();
    await expect(page.getByRole("heading", { name: "Log In" })).toBeVisible();
  });
});
