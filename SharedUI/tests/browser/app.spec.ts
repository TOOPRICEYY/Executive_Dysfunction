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
test("dialogs open at the top, notices stay on their page and each page has one title", async ({
  page,
}) => {
  await page.goto("/?preview=1");
  await page.getByRole("button", { name: "Edit Social feeds" }).click();
  const dialog = page.getByRole("dialog");
  await expect(dialog).toBeVisible();
  // A long editor used to open scrolled part-way down with a ring on "Close".
  expect(await dialog.evaluate((el) => el.scrollTop)).toBe(0);
  await expect(dialog).toBeFocused();
  await page.getByLabel("Name", { exact: true }).fill("Quiet evenings");
  await page.getByRole("button", { name: "Save group" }).click();
  await expect(page.getByRole("status")).toContainText(
    "No device settings changed",
  );
  // A saved-but-unenforced group must not read as blocking anywhere.
  await expect(page.getByText("Saved in this preview only")).toBeVisible();
  await page.getByRole("button", { name: "Settings", exact: true }).click();
  await expect(page.getByRole("status")).toHaveCount(0);
  await expect(page.getByRole("heading", { level: 1 })).toHaveCount(1);
  await expect(page.getByRole("heading", { level: 1 })).toHaveText("Settings");
});
test("a background status read never swallows the tap that follows it", async ({
  page,
}) => {
  await page.addInitScript((state) => {
    state.capabilities.push("lockdown");
    const listeners = new Set<(event: { data: unknown }) => void>();
    let reads = 0;
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
        host.sentCommands.push(request.command.type);
        const reply: any = { version: 1, id: request.id, ok: true };
        const read = request.command.type === "snapshot";
        reply.result = read ? { snapshot: structuredClone(state) } : {};
        // Only the first read is instant; later reads are slow, like a phone
        // waking its native engine.
        setTimeout(
          () => listeners.forEach((listener) => listener({ data: reply })),
          read && ++reads > 1 ? 1500 : 0,
        );
      },
    };
  }, previewSnapshot());
  await page.goto("/");
  const lockdown = page.getByRole("button", { name: "Lockdown", exact: true });
  await expect(lockdown).toBeEnabled();
  // The first touch after the app comes forward fires "focus" before "click".
  await page.evaluate(() => dispatchEvent(new Event("focus")));
  await expect(lockdown).toBeEnabled();
  await lockdown.click();
  await expect
    .poll(() => page.evaluate(() => (window as any).sentCommands))
    .toContain("startLockdown");
});
// The same bundle runs inside the Mac app and the Windows app. A filter that is
// on but has not confirmed the current rules may still be blocking, so those
// hosts read "not confirmed" rather than "not enforced".
for (const platform of ["macos", "windows"] as const) {
  test(`${platform} host: an unconfirmed filter never reads as blocking`, async ({
    page,
  }) => {
    await page.addInitScript(
      ({ state, platform }) => {
        state.platform = platform;
        delete state.summary;
        state.enforcementEnabled = true;
        state.enforcement = {
          state: "unknown",
          title: "Applying changes",
          detail: "The filter is applying the latest rules.",
        };
        for (const group of state.groups) {
          group.status = "unsupported";
          group.detail = "Blocking is not confirmed on this device.";
        }
        state.groups[0].now = {
          state: "blocking",
          headline: "Blocking now · until 5:00 PM",
          changesAt: new Date(Date.now() + 3600000).toISOString(),
        };
        const listeners = new Set<(event: { data: unknown }) => void>();
        const host = window as any;
        host.chrome ??= {};
        host.chrome.webview = {
          addEventListener(_: string, fn: (event: { data: unknown }) => void) {
            listeners.add(fn);
          },
          removeEventListener(
            _: string,
            fn: (event: { data: unknown }) => void,
          ) {
            listeners.delete(fn);
          },
          postMessage(request: any) {
            const reply = {
              version: 1,
              id: request.id,
              ok: true,
              result: { snapshot: structuredClone(state) },
            };
            queueMicrotask(() =>
              listeners.forEach((fn) => fn({ data: reply })),
            );
          },
        };
      },
      { state: previewSnapshot(), platform },
    );
    await page.goto("/");
    await expect(page.getByText("Check device enforcement")).toBeVisible();
    await expect(
      page.getByText("The filter is applying the latest rules.").first(),
    ).toBeVisible();
    await expect(
      page.getByText(/^Scheduled until .+ · not confirmed$/).first(),
    ).toBeVisible();
    await expect(page.getByText(/^Blocking now/)).toHaveCount(0);
    await expect(page.getByText(/· not enforced$/)).toHaveCount(0);
    expect(
      await page.evaluate(() => document.documentElement.scrollWidth),
    ).toBeLessThanOrEqual(page.viewportSize()!.width);
  });
}

// Screens that used to open a native window: the safety reset, the diagnostic
// report and starting a lockdown now live in this bundle and reach the host
// only through commands.
test("mac host: safety reset, diagnostics and lockdown stay in the shared screens", async ({
  page,
}) => {
  await page.addInitScript(
    ({ state }) => {
      state.platform = "macos";
      delete state.summary;
      state.capabilities = [
        ...state.capabilities,
        "enforcementControl",
        "lockdown",
        "lockdownForm",
        "diagnostics",
        "diagnosticsReport",
      ];
      state.enforcementEnabled = false;
      state.enforcement = {
        state: "error",
        title: "Safety locked",
        headline: "Web filter is safety locked",
        detail: "A previous start failed.",
        problem:
          "The web filter is safety locked after a failed start. Reset it before turning it on.",
        actions: [
          { id: "resetEnforcement", label: "Reset enforcement without restart" },
        ],
      };
      const sent: any[] = [];
      const listeners = new Set<(event: { data: unknown }) => void>();
      const host = window as any;
      host.__sent = sent;
      host.chrome ??= {};
      host.chrome.webview = {
        addEventListener(_: string, fn: (event: { data: unknown }) => void) {
          listeners.add(fn);
        },
        removeEventListener(_: string, fn: (event: { data: unknown }) => void) {
          listeners.delete(fn);
        },
        postMessage(request: any) {
          const command = request.command;
          if (command.type !== "snapshot") sent.push(command);
          let result: any = { snapshot: structuredClone(state) };
          if (command.type === "enforcementAction") {
            delete state.enforcement.problem;
            delete state.enforcement.actions;
            state.enforcement.headline = "Web filter is off";
            state.enforcement.state = "disabled";
            result = { snapshot: structuredClone(state) };
          } else if (command.type === "diagnostics") {
            result = command.copy
              ? { message: "Copied the readable report." }
              : {
                  diagnostics: {
                    text: "== HOST ==\nbuild  109",
                    findings: [
                      {
                        severity: "critical",
                        message: "The filter is not reporting.",
                        hint: "Reset enforcement.",
                      },
                    ],
                  },
                };
          } else if (command.type === "startLockdown") {
            state.lockdown = {
              endsAt: new Date(Date.now() + command.hours * 3600000).toISOString(),
              groupNames: state.groups
                .filter((g: any) => command.groupIDs.includes(g.id))
                .map((g: any) => g.name),
              detail: "Synced",
            };
            result = { snapshot: structuredClone(state) };
          }
          const reply = { version: 1, id: request.id, ok: true, result };
          queueMicrotask(() => listeners.forEach((fn) => fn({ data: reply })));
        },
      };
    },
    { state: previewSnapshot() },
  );
  await page.goto("/");
  const sent = () => page.evaluate(() => (window as any).__sent);

  // A locked filter explains itself and offers the reset, not a dead button.
  await expect(page.getByText(/safety locked after a failed start/)).toBeVisible();
  await expect(
    page.getByRole("button", { name: "Install / turn on web filter" }),
  ).toHaveCount(0);
  await page
    .getByRole("button", { name: "Reset enforcement without restart" })
    .click();
  await expect(page.getByText(/safety locked after a failed start/)).toHaveCount(0);
  await expect(
    page.getByRole("button", { name: "Install / turn on web filter" }),
  ).toBeVisible();
  expect((await sent()).at(-1)).toMatchObject({
    type: "enforcementAction",
    id: "resetEnforcement",
  });

  // Diagnostics render here, with the host doing the copy.
  await page.getByRole("button", { name: "Filter controls" }).click();
  await page.getByRole("button", { name: "Diagnostics" }).click();
  const report = page.getByRole("dialog", { name: "Diagnostic report" });
  await expect(report.getByText("1 critical finding")).toBeVisible();
  await expect(report.getByText("The filter is not reporting.")).toBeVisible();
  await expect(report.getByText(/build\s+109/)).toBeVisible();
  await report.getByRole("button", { name: "Copy report" }).click();
  await expect(report.getByText("Copied the readable report.")).toBeVisible();
  expect((await sent()).at(-1)).toMatchObject({ type: "diagnostics", copy: true });
  await report.getByRole("button", { name: "Close", exact: true }).last().click();

  // A lockdown is chosen here and sent as groups plus hours.
  const compact = (page.viewportSize()?.width ?? 1000) < 700;
  if (compact) await page.getByRole("button", { name: "Add" }).click();
  await page
    .getByRole(compact ? "menuitem" : "button", { name: /Lockdown/ })
    .first()
    .click();
  const lockdown = page.getByRole("dialog", { name: "Start a lockdown" });
  const start = lockdown.getByRole("button", { name: "Start lockdown" });
  await expect(start).toBeDisabled();
  await lockdown.getByRole("checkbox").first().check();
  await lockdown.getByRole("combobox").selectOption("12");
  await start.click();
  await expect(lockdown).toHaveCount(0);
  const last = (await sent()).at(-1);
  expect(last).toMatchObject({ type: "startLockdown", hours: 12 });
  expect(last.groupIDs).toHaveLength(1);
});
