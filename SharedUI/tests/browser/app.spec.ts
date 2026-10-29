import { test, expect } from "@playwright/test";
import { previewSnapshot } from "../../src/preview.ts";
test("native passage rejection does not unlock; acknowledgement preserves the editor draft", async ({
  page,
}) => {
  await page.addInitScript((state) => {
    state.groups[0].canEdit = false;
    const listeners = new Set<(event: { data: unknown }) => void>();
    const host = window as any;
    host.saved = null;
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
        const reply: any = {
          version: 1,
          id: request.id,
          ok: true,
          result: { snapshot: structuredClone(state) },
        };
        if (c.type === "requestGroupUnlock")
          reply.result = {
            challenge: {
              id: "native-challenge",
              title: "Unlock group changes",
              passage: "return to the present moment",
              detail: "Native policy confirmation",
              expiresAt: new Date(Date.now() + 300000).toISOString(),
            },
          };
        if (c.type === "submitChallenge") {
          if (c.typed !== "return to the present moment") {
            reply.ok = false;
            reply.error = "The passage does not match.";
          } else {
            state.revision = "unlocked-revision";
            state.groups[0].canEdit = true;
            reply.result = { snapshot: structuredClone(state) };
          }
        }
        if (c.type === "saveGroup") {
          host.saved = c;
          state.groups[0] = c.group;
          reply.result = { snapshot: structuredClone(state) };
        }
        queueMicrotask(() => listeners.forEach((fn) => fn({ data: reply })));
      },
    };
  }, previewSnapshot());
  await page.goto("/");
  await page.getByRole("button", { name: "Edit News & opinion" }).click();
  await page.getByLabel("Name", { exact: true }).fill("My preserved draft");
  await page.getByRole("button", { name: "Start unlock…" }).click();
  const challenge = page.getByRole("dialog", { name: "Unlock group changes" });
  await challenge.getByLabel("Type the confirmation passage").fill("wrong");
  await challenge.getByRole("button", { name: "Confirm passage" }).click();
  await expect(challenge.getByRole("alert")).toContainText("does not match");
  await challenge
    .getByLabel("Type the confirmation passage")
    .fill("return to the present moment");
  await challenge.getByRole("button", { name: "Confirm passage" }).click();
  await expect(challenge).toHaveCount(0);
  await expect(page.getByLabel("Name", { exact: true })).toHaveValue(
    "My preserved draft",
  );
  await page.getByRole("button", { name: "Save group" }).click();
  expect(await page.evaluate(() => (window as any).saved.revision)).toBe(
    "unlocked-revision",
  );
  await expect(
    page.getByRole("heading", { name: "My preserved draft" }),
  ).toBeVisible();
});
test("missing host is not silently replaced with fake enforcement", async ({
  page,
}) => {
  await page.goto("/");
  await expect(page.getByRole("alert")).toContainText("not connected");
  await expect(
    page.getByRole("heading", { name: "Interface preview" }),
  ).toHaveCount(0);
});
test("single interface supports status, editor, policies and history without overflow", async ({
  page,
}, testInfo) => {
  const errors: string[] = [];
  page.on("pageerror", (e) => errors.push(e.message));
  await page.goto("/?preview=1");
  await expect(
    page.getByRole("heading", { name: "Interface preview" }),
  ).toBeVisible();
  await expect(page.getByText(/^Temporarily allowed until/)).toBeVisible();
  await page.screenshot({
    path: testInfo.outputPath("status.png"),
    fullPage: true,
  });
  await page.getByRole("button", { name: "Edit Social feeds" }).click();
  await expect(page.getByRole("dialog")).toBeVisible();
  const dimensions = await page
    .getByRole("dialog")
    .evaluate((el) => ({ width: el.clientWidth, scroll: el.scrollWidth }));
  expect(dimensions.scroll).toBeLessThanOrEqual(dimensions.width);
  expect(
    (await page.getByRole("dialog").boundingBox())!.width,
  ).toBeLessThanOrEqual(page.viewportSize()!.width);
  await expect(
    page.getByText("Change protection", { exact: true }),
  ).toBeVisible();
  await page.getByLabel("Name", { exact: true }).fill("Careful social use");
  await page.getByRole("button", { name: "Save group" }).click();
  await expect(
    page.getByRole("heading", { name: "Careful social use", exact: true }),
  ).toBeVisible();
  await expect(page.getByRole("status")).toContainText(
    "No device settings changed",
  );
  const bypasses = page.getByRole("button", { name: /^Bypasses/ });
  if ((await bypasses.getAttribute("aria-expanded")) === "false")
    await bypasses.click();
  await page
    .getByRole("button", { name: "View all bypasses & configure…" })
    .click();
  await expect(page.getByRole("dialog")).toContainText(
    "Conscious intervention",
  );
  await page.getByRole("button", { name: "Close dialog" }).click();
  await page.getByRole("button", { name: "Settings", exact: true }).click();
  await page
    .getByRole("combobox", { name: "Theme", exact: true })
    .selectOption("dark");
  await expect(page.locator("html")).toHaveAttribute("data-theme", "dark");
  await page
    .getByRole("combobox", { name: "Accent", exact: true })
    .selectOption("green");
  await expect(page.locator("html")).toHaveAttribute("data-accent", "green");
  expect(
    await page.evaluate(() => document.documentElement.scrollWidth),
  ).toBeLessThanOrEqual(page.viewportSize()!.width);
  expect(errors).toEqual([]);
});
test("new group edits are shared and unsupported actions stay disabled", async ({
  page,
}) => {
  await page.goto("/?preview=1");
  await expect(
    page.getByRole("button", { name: "Lockdown", exact: true }),
  ).toBeDisabled();
  await page.getByRole("button", { name: "New blocking group" }).click();
  await page.getByLabel("Name", { exact: true }).fill("Evenings");
  await page.getByLabel("Website domains").fill("example.com\nexample.org");
  await page.getByText(/^Exact times/).click();
  await page.getByRole("button", { name: "Add window" }).click();
  await page.getByLabel("Allow temporary access with a passage").check();
  await page
    .getByRole("combobox", { name: "Change policy", exact: true })
    .selectOption("none");
  await expect(
    page.getByText("Permanent changes are easier", { exact: false }),
  ).toBeVisible();
  await page.getByRole("button", { name: "Save group" }).click();
  await expect(
    page.getByRole("heading", { name: "Evenings", exact: true }),
  ).toBeVisible();
  await expect(page.getByRole("dialog")).toHaveCount(0);
});

test("refresh cannot silently rebase a pending edit onto a newer native revision", async ({
  page,
}) => {
  await page.addInitScript((state) => {
    const listeners = new Set<(event: { data: unknown }) => void>();
    let refreshes = 0;
    const host = window as any;
    host.sentCommands = [];
    host.chrome ??= {};
    host.chrome.webview = {
      addEventListener(
        _: string,
        listener: (event: { data: unknown }) => void,
      ) {
        listeners.add(listener);
      },
      removeEventListener(
        _: string,
        listener: (event: { data: unknown }) => void,
      ) {
        listeners.delete(listener);
      },
      postMessage(request: any) {
        host.sentCommands.push(request.command);
        const reply: any = { version: 1, id: request.id, ok: true };
        if (request.command.type === "snapshot") {
          state.revision =
            ++refreshes === 1 ? "before-refresh" : "after-refresh";
          reply.result = { snapshot: structuredClone(state) };
        } else {
          reply.ok = false;
          reply.error = "Stale edit rejected by native engine";
        }
        queueMicrotask(() =>
          listeners.forEach((listener) => listener({ data: reply })),
        );
      },
    };
  }, previewSnapshot());
  await page.goto("/");
  await page.getByRole("button", { name: "Edit Social feeds" }).click();
  await page.evaluate(() => dispatchEvent(new Event("focus")));
  await expect(page.locator("footer")).toContainText("after-refresh");
  await page.getByRole("button", { name: "Save group" }).click();
  await expect(page.getByRole("dialog").getByRole("alert")).toContainText(
    "Stale edit rejected",
  );
  expect(
    await page.evaluate(
      () =>
        (window as any).sentCommands.find((c: any) => c.type === "saveGroup")
          .revision,
    ),
  ).toBe("before-refresh");
});
