import { test, expect, type Page } from "@playwright/test";
import { previewSnapshot } from "../../src/preview.ts";

/** A fake native host. Each test shapes the snapshot; the host records commands. */
async function installHost(page: Page, waiting: boolean) {
  const state = previewSnapshot();
  state.platform = "macos";
  state.enforcement = {
    state: "active",
    title: "Web filter on",
    headline: "WEB FILTER ON",
    detail: "Fake host for tests.",
  };
  state.capabilities = ["editGroups", "temporaryAccess"];
  const g = state.groups[0];
  g.temporaryPolicy = { ...g.temporaryPolicy, waitMinutes: 10 };
  g.suspendedUntil = undefined;
  if (waiting) {
    const opens = new Date(Date.now() + 10 * 60_000).toISOString();
    g.status = "blocking";
    g.detail = "Access opens soon · blocking until then";
    g.accessOpensAt = opens;
    g.now = {
      state: "waiting",
      changesAt: opens,
      headline: "Access opens at 3:10 PM · blocking until then",
    };
  }
  await page.addInitScript((initial) => {
    const state = initial;
    const listeners = new Set<(event: { data: unknown }) => void>();
    const host = window as any;
    host.sentCommands = [];
    host.chrome ??= {};
    host.chrome.webview = {
      addEventListener(_: string, fn: (event: { data: unknown }) => void) {
        listeners.add(fn);
      },
      removeEventListener(_: string, fn: (event: { data: unknown }) => void) {
        listeners.delete(fn);
      },
      postMessage(request: any) {
        const c = request.command;
        host.sentCommands.push(c);
        if (c.type === "cancelTemporaryAccess") {
          const g = state.groups.find((v: any) => v.id === c.groupID);
          delete g.accessOpensAt;
          g.now = { state: "blocking", headline: "Blocking now · always on" };
          state.revision = "after-cancel";
        }
        if (c.type === "saveGroup") {
          const i = state.groups.findIndex((v: any) => v.id === c.group.id);
          state.groups[i] = { ...state.groups[i], ...c.group };
        }
        const reply: any = {
          version: 1,
          id: request.id,
          ok: true,
          result: { snapshot: structuredClone(state) },
        };
        queueMicrotask(() => listeners.forEach((fn) => fn({ data: reply })));
      },
    };
  }, state);
}

const noHorizontalOverflow = (page: Page) =>
  page.evaluate(
    () =>
      document.documentElement.scrollWidth <=
      document.documentElement.clientWidth,
  );

test("a waiting group reads as blocking, says when access opens and can be cancelled", async ({
  page,
}) => {
  await installHost(page, true);
  await page.goto("/");
  const row = page.getByRole("button", { name: "Edit News & opinion" });
  await expect(row).toBeVisible();
  // Still a blocking row: blocking styling, the host's headline, never "allowed".
  await expect(row).toHaveClass(/is-blocking/);
  await expect(row).toHaveClass(/now-waiting/);
  await expect(row).toContainText(
    "Access opens at 3:10 PM · blocking until then",
  );
  await expect(row).not.toContainText("Temporarily allowed");
  const pending = page.locator('[data-group-pending="news"]');
  await expect(pending.getByRole("status")).toContainText(
    /Access requested · opens at .+\. Blocking until then\./,
  );
  expect(await noHorizontalOverflow(page)).toBe(true);
  await pending.getByRole("button", { name: "Cancel request" }).click();
  await expect(pending).toHaveCount(0);
  const sent = await page.evaluate(() => (window as any).sentCommands);
  expect(
    sent.find((c: any) => c.type === "cancelTemporaryAccess"),
  ).toMatchObject({ groupID: "news" });
  await expect(row).toContainText("Blocking now");
});

test("the editor shows the pending access with a cancel action", async ({
  page,
}) => {
  await installHost(page, true);
  await page.goto("/");
  await page.getByRole("button", { name: "Edit News & opinion" }).click();
  const pending = page.locator("[data-access-pending]");
  await expect(pending).toContainText(/Access opens at .+Still blocking/);
  await pending.getByRole("button", { name: "Cancel request" }).click();
  await expect(pending).toHaveCount(0);
  expect(await noHorizontalOverflow(page)).toBe(true);
});

test("the wait field edits waitMinutes and explains it", async ({ page }) => {
  await installHost(page, false);
  await page.goto("/");
  await page.getByRole("button", { name: "Edit News & opinion" }).click();
  const field = page.getByLabel("Wait before access opens (minutes)");
  await expect(field).toHaveValue("10");
  const note = page.locator("[data-wait-note]");
  await expect(note).toContainText(
    "Access opens 10 minutes after you finish the passage.",
  );
  // The preview group is locked: say what the host will refuse.
  await expect(note).toContainText("a shorter one needs this group unlocked");
  await field.fill("0");
  await expect(note).toContainText("No wait");
  await field.fill("25");
  await expect(note).toContainText("Access opens 25 minutes after");
  expect(await noHorizontalOverflow(page)).toBe(true);
  await page.getByRole("button", { name: "Save group" }).click();
  const saved = await page.evaluate(() =>
    (window as any).sentCommands.find((c: any) => c.type === "saveGroup"),
  );
  expect(saved.group.temporaryPolicy.waitMinutes).toBe(25);
});

test("the access dialog says when access opens before the person commits", async ({
  page,
}) => {
  await installHost(page, false);
  await page.goto("/");
  await page.getByRole("button", { name: "Edit News & opinion" }).click();
  await page.getByRole("button", { name: "Disable temporarily…" }).click();
  const dialog = page.getByRole("dialog", { name: /Temporary access/ });
  const timing = dialog.locator("[data-access-timing]");
  await expect(timing).toContainText(
    "Access opens 10 minutes after you finish the passage, then lasts 1 minute.",
  );
  await dialog.getByLabel("For how long?").selectOption("30");
  await expect(timing).toContainText(
    "Access opens 10 minutes after you finish the passage, then lasts 30 minutes.",
  );
  expect(await noHorizontalOverflow(page)).toBe(true);
});
