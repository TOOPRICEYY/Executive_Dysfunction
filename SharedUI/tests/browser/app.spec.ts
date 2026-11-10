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
          {
            id: "resetEnforcement",
            label: "Reset enforcement without restart",
          },
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
              endsAt: new Date(
                Date.now() + command.hours * 3600000,
              ).toISOString(),
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
  await expect(
    page.getByText(/safety locked after a failed start/),
  ).toBeVisible();
  await expect(
    page.getByRole("button", { name: "Install / turn on web filter" }),
  ).toHaveCount(0);
  await page
    .getByRole("button", { name: "Reset enforcement without restart" })
    .click();
  await expect(
    page.getByText(/safety locked after a failed start/),
  ).toHaveCount(0);
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
  expect((await sent()).at(-1)).toMatchObject({
    type: "diagnostics",
    copy: true,
  });
  await report
    .getByRole("button", { name: "Close", exact: true })
    .last()
    .click();

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

// Creating and changing a retreat used to open a native editor. Hosts that
// advertise retreatForm get the whole retreat back as one command.
test("retreats are created and edited in the shared screens", async ({
  page,
}) => {
  await page.addInitScript(
    ({ state }) => {
      state.platform = "ios";
      delete state.summary;
      state.capabilities = [...state.capabilities, "retreats", "retreatForm"];
      state.retreats.push({
        id: "draft",
        name: "Exam week",
        startsAt: "2030-03-01T08:00:00Z",
        endsAt: "2030-03-08T08:00:00Z",
        state: "draft",
        version: 1,
        groupNames: ["News copy"],
        changePolicyLabel: "passageOnly",
        canRequestEnd: false,
        canEdit: true,
        goal: "Revise",
        changePolicy: { kind: "passage", words: 60, delayDays: 0 },
        groupIDs: ["news-copy"],
        groupChoices: [
          { id: "news-copy", name: "News copy" },
          { id: "video", name: "Video" },
        ],
      });
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
          const result: any = { snapshot: structuredClone(state) };
          if (command.type === "saveRetreat")
            result.message = "Retreat draft saved.";
          const reply = { version: 1, id: request.id, ok: true, result };
          queueMicrotask(() => listeners.forEach((fn) => fn({ data: reply })));
        },
      };
    },
    { state: previewSnapshot() },
  );
  await page.goto("/");
  const sent = () => page.evaluate(() => (window as any).__sent);
  await page.getByRole("button", { name: "Retreats" }).first().click();

  // A running retreat is held by its policy and offers no edit here.
  await expect(
    page.getByRole("button", { name: "Edit A quieter month" }),
  ).toHaveCount(0);

  await page.getByRole("button", { name: "New retreat" }).click();
  const dialog = page.getByRole("dialog", { name: "New retreat" });
  const save = dialog.getByRole("button", { name: "Save draft" });
  await expect(save).toBeDisabled();
  await dialog.getByLabel("Name", { exact: true }).fill("  Quiet weekend ");
  await expect(save).toBeDisabled();
  await dialog.getByRole("checkbox", { name: /Social feeds/ }).check();
  await dialog
    .getByPlaceholder("What should this make room for?")
    .fill("Read a book");
  await dialog.getByLabel("Starts", { exact: true }).fill("2030-01-02T09:30");
  await dialog.getByLabel("Ends", { exact: true }).fill("2030-01-02T09:00");
  await expect(save).toBeDisabled();
  await expect(
    dialog.getByText("The retreat has to end after it starts."),
  ).toBeVisible();
  await dialog.getByLabel("Ends", { exact: true }).fill("2030-01-04T18:00");
  await dialog.getByRole("combobox").selectOption("checkpoints");
  await dialog.getByLabel("Unlock wait (days)").fill("5");
  await dialog.getByLabel("Passage (words)").fill("120");
  expect(
    await page.evaluate(() => document.documentElement.scrollWidth),
  ).toBeLessThanOrEqual(page.viewportSize()!.width);
  expect(
    await dialog.evaluate((d) => d.scrollWidth - d.clientWidth),
  ).toBeLessThanOrEqual(0);
  await expect(save).toBeEnabled();
  await save.click();
  await expect(dialog).toHaveCount(0);
  await expect(page.getByText("Retreat draft saved.")).toBeVisible();
  const utc = (y: number, m: number, d: number, h: number, mi: number) =>
    page.evaluate(
      ([y, m, d, h, mi]) =>
        new Date(y, m, d, h, mi).toISOString().replace(".000Z", "Z"),
      [y, m, d, h, mi],
    );
  expect((await sent()).at(-1)).toEqual({
    type: "saveRetreat",
    revision: "preview-1",
    retreat: {
      name: "Quiet weekend",
      goal: "Read a book",
      startsAt: await utc(2030, 0, 2, 9, 30),
      endsAt: await utc(2030, 0, 4, 18, 0),
      groupIDs: ["social"],
      changePolicy: { kind: "checkpoints", words: 120, delayDays: 5 },
      startNow: false,
    },
  });

  // A draft opens on what is saved, choosing among the host's own copies.
  await page.getByRole("button", { name: "Edit Exam week" }).click();
  const edit = page.getByRole("dialog", { name: "Edit retreat" });
  await expect(edit.getByLabel("Name", { exact: true })).toHaveValue(
    "Exam week",
  );
  await expect(
    edit.getByPlaceholder("What should this make room for?"),
  ).toHaveValue("Revise");
  await expect(edit.getByRole("checkbox", { name: /News copy/ })).toBeChecked();
  await expect(
    edit.getByRole("checkbox", { name: /Social feeds/ }),
  ).toHaveCount(0);
  await expect(edit.getByRole("combobox")).toHaveValue("passage");
  await edit.getByRole("checkbox", { name: /Video/ }).check();
  await edit
    .getByRole("checkbox", { name: /Start it now|Schedule it now/ })
    .check();
  await edit.getByRole("button", { name: "Schedule retreat" }).click();
  await expect(edit).toHaveCount(0);
  expect((await sent()).at(-1)).toMatchObject({
    type: "saveRetreat",
    retreat: {
      id: "draft",
      name: "Exam week",
      startsAt: "2030-03-01T08:00:00Z",
      endsAt: "2030-03-08T08:00:00Z",
      groupIDs: ["news-copy", "video"],
      changePolicy: { kind: "passage", words: 60, delayDays: 0 },
      startNow: true,
    },
  });
});

const noOverflow = async (page: import("@playwright/test").Page) => {
  expect(
    await page.evaluate(() => document.documentElement.scrollWidth),
  ).toBeLessThanOrEqual(page.viewportSize()!.width);
  for (const d of await page.getByRole("dialog").all())
    expect(
      await d.evaluate((v) => v.scrollWidth - v.clientWidth),
    ).toBeLessThanOrEqual(0);
};

// Everything the retired "Advanced native controls" window held on a Mac is
// in the shared screens; the host does only what is OS-owned.
test("mac host: filter controls, lockdown locks, exports and group details are shared", async ({
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
        "lockdownPolicy",
        "diagnostics",
        "diagnosticsReport",
        "diagnosticsExport",
        "debugTrace",
        "groupDetails",
        "otherTargets",
        "cancelUnlock",
        "advancedControls",
      ];
      state.enforcementEnabled = true;
      state.enforcement = {
        state: "active",
        title: "Active",
        headline: "Web filter on",
        detail: "The filter is enforcing.",
        held: [
          {
            name: "News & opinion",
            appliesAt: new Date(Date.now() + 86400000).toISOString(),
          },
        ],
        actions: [
          {
            id: "removeNetworkExtension",
            label: "Remove Network Extension…",
            placement: "controls",
            danger: true,
          },
        ],
      };
      state.lockdownOptions = {
        hours: [1, 4, 12, 24, 72, 168, 720],
        locks: ["passage", "delay", "checkpoints"],
      };
      state.debugTrace = { recording: false };
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
          if (command.type === "enforcementAction")
            result = {
              challenge: {
                id: "c1",
                title: "Remove Network Extension",
                passage: "I choose to remove the filter.",
                expiresAt: new Date(Date.now() + 1800000).toISOString(),
                detail: "Type the passage exactly.",
              },
            };
          else if (command.type === "diagnostics")
            result = {
              diagnostics: {
                text: "== HOST ==",
                findings: [],
                journal: [
                  {
                    at: new Date().toISOString(),
                    title: "Emergency disable",
                    detail: "This Mac",
                  },
                ],
              },
            };
          else if (command.type === "exportDiagnostics")
            result = { message: "Wrote 2 files to Desktop." };
          else if (command.type === "setDebugTrace") {
            state.debugTrace.recording = command.enabled;
            result = {
              snapshot: structuredClone(state),
              message: "Trace recording.",
            };
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
  const compact = (page.viewportSize()?.width ?? 1000) < 700;

  // Filter controls: held changes are visible, removal asks the host for its passage.
  await page.getByRole("button", { name: "Filter controls" }).click();
  await expect(page.getByRole("button", { name: /Advanced/ })).toHaveCount(0);
  await expect(page.getByText(/looser version arrived without/)).toBeVisible();
  await noOverflow(page);
  await page.getByRole("button", { name: "Remove Network Extension…" }).click();
  const challenge = page.getByRole("dialog", {
    name: "Remove Network Extension",
  });
  await expect(challenge).toBeVisible();
  expect((await sent()).at(-1)).toMatchObject({
    type: "enforcementAction",
    id: "removeNetworkExtension",
  });
  await challenge.getByRole("button", { name: "Close dialog" }).click();

  // A lockdown chooses the Mac window's lock modes and its 30-day duration.
  if (compact) await page.getByRole("button", { name: "Add" }).click();
  await page
    .getByRole(compact ? "menuitem" : "button", { name: /Lockdown/ })
    .first()
    .click();
  const lockdown = page.getByRole("dialog", { name: "Start a lockdown" });
  await lockdown.getByRole("checkbox").first().check();
  await lockdown.getByLabel("For how long?").selectOption("720");
  await lockdown.getByLabel("Lock mode").selectOption("delay");
  await lockdown.getByLabel("Passage length (words)").fill("120");
  await lockdown.getByLabel("Extra delay before early exit (days)").fill("31");
  await expect(
    lockdown.getByRole("button", { name: "Start lockdown" }),
  ).toBeDisabled();
  await lockdown.getByLabel("Extra delay before early exit (days)").fill("2");
  await noOverflow(page);
  await lockdown.getByRole("button", { name: "Start lockdown" }).click();
  expect((await sent()).at(-1)).toMatchObject({
    type: "startLockdown",
    hours: 720,
    lock: { kind: "delay", words: 120, delayDays: 2 },
  });

  // A new group can be allow-only, with categories and a daily limit.
  if (compact) await page.getByRole("button", { name: "Add" }).click();
  await page
    .getByRole(compact ? "menuitem" : "button", { name: /New Blocking Group/i })
    .first()
    .click();
  const editor = page.getByRole("dialog", { name: "New blocking group" });
  await editor.getByLabel("Name", { exact: true }).fill("Only work");
  await editor.getByLabel("Enforcement").selectOption("allowOnly");
  await editor.getByRole("checkbox", { name: "Shopping", exact: true }).check();
  await editor
    .getByRole("checkbox", { name: "Daily limit", exact: true })
    .check();
  await editor.getByLabel("Daily limit (minutes)").fill("45");
  await editor.getByText("Identifiers & other platforms").click();
  await editor
    .getByLabel("Add Mac bundle identifiers")
    .fill("com.example.game\n\ncom.example.game\n");
  await editor
    .getByLabel("Windows executable paths")
    .fill("C:\\Games\\game.exe");
  await noOverflow(page);
  await editor.getByRole("button", { name: "Save group" }).click();
  expect((await sent()).at(-1)).toMatchObject({
    type: "saveGroup",
    group: {
      name: "Only work",
      mode: "allowOnly",
      categories: ["shopping"],
      budget: { dailyMinutes: 45, weeklyMinutes: null },
      changePolicy: { editWindowHours: 24 },
      applications: ["com.example.game"],
      otherTargets: {
        windowsPaths: ["C:\\Games\\game.exe"],
        windowsPublishers: [],
      },
    },
  });
  await expect(editor).toHaveCount(0);

  // Diagnostics show the tamper journal and export through the host.
  await page.getByRole("button", { name: "Settings" }).first().click();
  await expect(page.getByRole("button", { name: /Advanced/ })).toHaveCount(0);
  await page.getByRole("checkbox", { name: "Record debug trace" }).check();
  expect((await sent()).at(-1)).toEqual({
    type: "setDebugTrace",
    enabled: true,
  });
  await page.getByRole("button", { name: "Open diagnostics" }).click();
  const report = page.getByRole("dialog", { name: "Diagnostic report" });
  await expect(report.getByText("Emergency disable")).toBeVisible();
  await report.getByRole("button", { name: "Export files…" }).click();
  await expect(report.getByText("Wrote 2 files to Desktop.")).toBeVisible();
  expect((await sent()).at(-1)).toEqual({
    type: "exportDiagnostics",
    names: false,
  });
  await noOverflow(page);
});

// The iPhone's native Settings (Screen Time, iCloud, hardening, app-wide
// change protection, recovery) and the block screen's request are shared.
test("iphone host: settings, protection and block-screen requests are shared", async ({
  page,
}) => {
  await page.addInitScript(
    ({ state }) => {
      state.platform = "ios";
      delete state.summary;
      state.capabilities = [
        ...state.capabilities,
        "enforcementControl",
        "temporaryAccess",
        "protection",
        "syncNow",
        "accessRequests",
        "groupDetails",
        "classifyWebsites",
      ];
      state.enforcementEnabled = true;
      state.groups[0].temporaryPolicy.allowed = true;
      state.protection = {
        antiUninstall: { on: false },
        appLock: {
          enabled: true,
          unlockDelayDays: 3,
          repeatConfirmations: false,
          passageWordCount: 40,
          confirmationWindowHours: 24,
          editWindowHours: 24,
          unlock: { phase: "idle" },
        },
      };
      state.accessRequest = {
        id: "req",
        groupIDs: [state.groups[0].id],
        minutes: 10,
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
          if (command.type === "saveAppLock")
            state.protection.appLock = {
              ...command.settings,
              unlock: { phase: "idle" },
            };
          if (command.type === "setAntiUninstall")
            state.protection.antiUninstall.on = command.enabled;
          if (command.type === "dismissAccessRequest")
            delete state.accessRequest;
          const result: any =
            command.type === "classifyWebsites"
              ? {
                  classified: [
                    {
                      domain: "reddit.com",
                      category: "social",
                      source: "heuristic",
                    },
                  ],
                  message: "Classified 1 website.",
                }
              : { snapshot: structuredClone(state) };
          const reply = { version: 1, id: request.id, ok: true, result };
          queueMicrotask(() => listeners.forEach((fn) => fn({ data: reply })));
        },
      };
    },
    { state: previewSnapshot() },
  );
  await page.goto("/");
  const sent = () => page.evaluate(() => (window as any).__sent);

  // Websites are classified on the device and saved with the group.
  await page
    .getByRole("button", { name: "Edit News & opinion" })
    .first()
    .click();
  const editor = page.getByRole("dialog", { name: "Edit blocking group" });
  await expect(editor.getByText("Identifiers & other platforms")).toHaveCount(
    0,
  );
  await editor
    .getByRole("button", { name: "Classify websites automatically" })
    .click();
  await expect(
    editor.getByRole("checkbox", { name: "Social", exact: true }),
  ).toBeChecked();
  await noOverflow(page);
  await editor.getByRole("button", { name: "Save group" }).click();
  expect((await sent()).at(-1)).toMatchObject({
    type: "saveGroup",
    group: {
      id: "news",
      categories: ["social"],
      domainCategories: [
        { domain: "reddit.com", category: "social", source: "heuristic" },
      ],
    },
  });

  // A block screen's request is answered here, for the group and time it chose.
  await expect(
    page.getByText(/A block screen asked for more time \(10 minutes\)/),
  ).toBeVisible();
  await noOverflow(page);
  await page.getByRole("button", { name: "Answer…" }).click();
  const access = page.getByRole("dialog", { name: /Temporary access/ });
  await expect(access.getByLabel("For how long?")).toBeDisabled();
  await access.getByRole("textbox").fill("Reply to the one message I need");
  await access.getByRole("button", { name: "Continue to passage" }).click();
  expect((await sent()).at(-1)).toMatchObject({
    type: "answerAccessRequest",
    requestID: "req",
    minutes: 10,
    reason: "conscious",
    reflection: "Reply to the one message I need",
  });
  await page.getByRole("button", { name: "Dismiss" }).click();
  await expect(page.getByText(/A block screen asked/)).toHaveCount(0);

  await page.getByRole("button", { name: "Settings" }).first().click();
  await page.getByRole("button", { name: "Sync now" }).click();
  expect((await sent()).at(-1)).toEqual({ type: "syncNow" });

  // Turning app-deletion protection on asks first, exactly as natively.
  await page.getByRole("checkbox", { name: "Prevent app deletion" }).click();
  const confirm = page.getByRole("dialog", {
    name: "Prevent all app deletion?",
  });
  await confirm.getByRole("button", { name: "Turn on" }).click();
  expect((await sent()).at(-1)).toMatchObject({
    type: "setAntiUninstall",
    enabled: true,
  });
  await expect(
    page.getByRole("checkbox", { name: "Prevent app deletion" }),
  ).toBeChecked();

  // App-wide change protection: saved by the host, unlocked through a passage.
  const save = page.getByRole("button", { name: "Save change protection" });
  await expect(save).toBeDisabled();
  await page.getByLabel("Passage length (words)").fill("60");
  await save.click();
  expect((await sent()).at(-1)).toMatchObject({
    type: "saveAppLock",
    settings: { enabled: true, passageWordCount: 60, unlockDelayDays: 3 },
  });
  await page.getByRole("button", { name: "Start unlock…" }).click();
  expect((await sent()).at(-1)).toMatchObject({ type: "requestAppUnlock" });

  await page
    .getByRole("button", { name: "Reset Screen Time restrictions…" })
    .click();
  await page
    .getByRole("dialog", { name: "Clear all restrictions?" })
    .getByRole("button", { name: "Clear restrictions" })
    .click();
  expect((await sent()).at(-1)).toMatchObject({ type: "resetScreenTime" });
  await expect(page.getByRole("button", { name: /Advanced/ })).toHaveCount(0);
  await noOverflow(page);
});

// A running retreat is edited here; the host decides which edits need its
// change policy, and the edit keeps going on the revision the unlock made.
test("running retreats are edited behind their change policy and past ones recreated", async ({
  page,
}) => {
  await page.addInitScript(
    ({ state }) => {
      state.platform = "macos";
      delete state.summary;
      state.capabilities = [
        ...state.capabilities,
        "retreats",
        "retreatForm",
        "retreatChanges",
        "cancelUnlock",
        "recreateRetreat",
      ];
      Object.assign(state.retreats[0], {
        canEdit: true,
        goal: "Read",
        changePolicy: { kind: "delay", words: 40, delayDays: 3 },
        groupIDs: ["news-copy"],
        groupChoices: [
          { id: "news-copy", name: "News copy" },
          { id: "video", name: "Video" },
        ],
        unlock: { phase: "idle" },
      });
      state.retreats.push({
        id: "past",
        name: "Last spring",
        startsAt: "2026-03-01T08:00:00Z",
        endsAt: "2026-03-08T08:00:00Z",
        state: "completed",
        version: 1,
        groupNames: ["News copy"],
        changePolicyLabel: "passageOnly",
        canRequestEnd: false,
      });
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
          if (command.type === "requestRetreatUnlock") {
            state.retreats[0].unlock = {
              phase: "unlocked",
              at: new Date(Date.now() + 3600000).toISOString(),
            };
            state.revision = "preview-2";
          }
          const result: any = { snapshot: structuredClone(state) };
          if (command.type === "recreateRetreat")
            result.message = "Recreated as a draft.";
          const reply = { version: 1, id: request.id, ok: true, result };
          queueMicrotask(() => listeners.forEach((fn) => fn({ data: reply })));
        },
      };
    },
    { state: previewSnapshot() },
  );
  await page.goto("/");
  const sent = () => page.evaluate(() => (window as any).__sent);
  await page.getByRole("button", { name: "Retreats" }).first().click();
  await page.getByRole("button", { name: "Edit A quieter month" }).click();
  const edit = page.getByRole("dialog", { name: "Edit retreat" });
  await expect(edit.getByText("Locked", { exact: true })).toBeVisible();
  await expect(
    edit.getByRole("checkbox", { name: /Start it now|Schedule it now/ }),
  ).toHaveCount(0);
  await edit.getByRole("button", { name: "Start unlock…" }).click();
  expect((await sent()).at(-1)).toMatchObject({
    type: "requestRetreatUnlock",
    retreatID: "retreat",
  });
  await expect(edit.getByRole("button", { name: "Re-lock now" })).toBeVisible();
  await edit.getByRole("checkbox", { name: /News copy/ }).uncheck();
  await edit.getByRole("checkbox", { name: /Video/ }).check();
  await noOverflow(page);
  await edit.getByRole("button", { name: "Save changes" }).click();
  expect((await sent()).at(-1)).toMatchObject({
    type: "saveRetreat",
    revision: "preview-2",
    retreat: { id: "retreat", groupIDs: ["video"], startNow: false },
  });

  await page.getByRole("button", { name: "History" }).first().click();
  await page.getByRole("button", { name: "Recreate Last spring" }).click();
  expect((await sent()).at(-1)).toMatchObject({
    type: "recreateRetreat",
    retreatID: "past",
  });
  await expect(page.getByText("Recreated as a draft.")).toBeVisible();
});
