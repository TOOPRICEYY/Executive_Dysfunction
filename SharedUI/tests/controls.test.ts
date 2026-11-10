import { test } from "node:test";
import assert from "node:assert/strict";
import {
  appLockProblem,
  groupDetailsProblem,
  lockdownLock,
  lockdownLockProblem,
  unlockView,
  withGroupDetails,
} from "../src/controls.ts";
import { isSnapshot, type Group } from "../src/contract.ts";
import { previewSnapshot } from "../src/preview.ts";

const group = (): Group => structuredClone(previewSnapshot().groups[0]);

test("a group without details gets the native defaults, and sent ones are kept", () => {
  const plain = group();
  delete plain.mode;
  delete plain.categories;
  delete plain.budget;
  const filled = withGroupDetails(plain);
  assert.equal(filled.mode, "block");
  assert.deepEqual(filled.categories, []);
  assert.deepEqual(filled.budget, { dailyMinutes: null, weeklyMinutes: null });
  assert.equal(filled.changePolicy.editWindowHours, 24);
  const sent = {
    ...plain,
    mode: "allowOnly" as const,
    categories: ["news"],
    budget: { weeklyMinutes: 300 },
    changePolicy: { ...plain.changePolicy, editWindowHours: 3 },
  };
  const kept = withGroupDetails(sent);
  assert.equal(kept.mode, "allowOnly");
  assert.deepEqual(kept.categories, ["news"]);
  assert.deepEqual(kept.budget, { dailyMinutes: null, weeklyMinutes: 300 });
  assert.equal(kept.changePolicy.editWindowHours, 3);
});

test("group details outside the hosts' ranges are named before asking", () => {
  const g = withGroupDetails(group());
  assert.equal(groupDetailsProblem(g), "");
  assert.match(
    groupDetailsProblem({ ...g, categories: ["casino"] }),
    /categories/,
  );
  assert.match(
    groupDetailsProblem({ ...g, budget: { dailyMinutes: 0 } }),
    /daily limit/,
  );
  assert.match(
    groupDetailsProblem({ ...g, budget: { weeklyMinutes: 10081 } }),
    /weekly limit/,
  );
  assert.match(
    groupDetailsProblem({
      ...g,
      changePolicy: { ...g.changePolicy, editWindowHours: 73 },
    }),
    /edit window/,
  );
});

test("app lock and lockdown lock ranges match the native steppers", () => {
  const lock = {
    enabled: true,
    unlockDelayDays: 3,
    repeatConfirmations: false,
    passageWordCount: 40,
    confirmationWindowHours: 24,
    editWindowHours: 24,
  };
  assert.equal(appLockProblem(lock), "");
  assert.match(appLockProblem({ ...lock, passageWordCount: 19 }), /passage/);
  assert.match(appLockProblem({ ...lock, editWindowHours: 0 }), /edit window/);
  assert.equal(
    lockdownLockProblem({ kind: "passage", words: 80, delayDays: 99 }),
    "",
  );
  assert.match(
    lockdownLockProblem({ kind: "delay", words: 80, delayDays: 31 }),
    /delay/,
  );
  assert.deepEqual(lockdownLock({ kind: "passage", words: 80, delayDays: 4 }), {
    kind: "passage",
    words: 80,
    delayDays: 0,
  });
});

test("unlock wording offers only the step the host's phase allows", () => {
  const f = () => "Tue 9:00";
  assert.deepEqual(unlockView(undefined, f), {
    title: "Locked",
    request: "Start unlock…",
  });
  assert.equal(
    unlockView({ phase: "waiting", at: "2030-01-01T00:00:00Z" }, f).request,
    undefined,
  );
  assert.equal(
    unlockView({ phase: "waiting", at: "2030-01-01T00:00:00Z" }, f).title,
    "Unlocking · opens Tue 9:00",
  );
  assert.equal(
    unlockView({ phase: "confirmationDue" }, f).request,
    "Type the checkpoint passage…",
  );
  assert.equal(unlockView({ phase: "unlocked" }, f).cancel, "Re-lock now");
});

test("snapshots with the new optional sections validate, and malformed ones do not", () => {
  const s = previewSnapshot();
  assert.ok(isSnapshot(s));
  const extended = {
    ...structuredClone(s),
    lockdownOptions: { hours: [1, 720], locks: ["passage", "delay"] },
    debugTrace: { recording: true },
    protection: {
      antiUninstall: { on: false },
      appLock: {
        enabled: true,
        unlockDelayDays: 3,
        repeatConfirmations: true,
        passageWordCount: 40,
        confirmationWindowHours: 24,
        editWindowHours: 24,
        unlock: { phase: "idle" },
      },
      pendingSync: false,
    },
    accessRequest: { id: "r", groupIDs: ["g"], minutes: 10 },
  };
  extended.enforcement.held = [
    { name: "News", appliesAt: "2030-01-01T00:00:00Z" },
  ];
  extended.enforcement.actions = [
    {
      id: "removeNetworkExtension",
      label: "Remove",
      placement: "controls",
      danger: true,
    },
  ];
  assert.ok(isSnapshot(extended));
  const bad = (patch: (v: any) => void) => {
    const v: any = structuredClone(extended);
    patch(v);
    return isSnapshot(v);
  };
  assert.equal(
    bad((v) => (v.lockdownOptions.hours = [0])),
    false,
  );
  assert.equal(
    bad((v) => (v.lockdownOptions.locks = ["none"])),
    false,
  );
  assert.equal(
    bad((v) => (v.protection.appLock.passageWordCount = 5)),
    false,
  );
  assert.equal(
    bad((v) => (v.protection.appLock.unlock = { phase: "open" })),
    false,
  );
  assert.equal(
    bad((v) => (v.enforcement.actions[0].placement = "side")),
    false,
  );
  assert.equal(
    bad((v) => (v.enforcement.held = [{ name: "x" }])),
    false,
  );
  assert.equal(
    bad((v) => (v.accessRequest.groupIDs = "g")),
    false,
  );
  assert.equal(
    bad((v) => (v.groups[0].categories = ["casino"])),
    false,
  );
  assert.equal(
    bad((v) => (v.groups[0].budget = { dailyMinutes: 0 })),
    false,
  );
  assert.equal(
    bad((v) => (v.retreats[0].unlock = { phase: "x" })),
    false,
  );
});

test("a block-screen request naming a running retreat's copy can be answered", async () => {
  // Regression: only `groups` was searched, so a request for a retreat copy
  // (sent in `retreatGroups`) left the Answer button disabled.
  const { accessRequestChoices } = await import("../src/presentation.ts");
  const s = structuredClone(previewSnapshot());
  s.groups[0].temporaryPolicy.allowed = true;
  const copy = {
    id: "retreat-copy",
    name: s.groups[0].name,
    now: { state: "blocking" as const, headline: "Blocking" },
    lock: "delay" as const,
    delayDays: 3,
    targets: "1 website",
    temporaryPolicy: {
      allowed: true,
      words: 60,
      maximumMinutes: 30,
      resetDays: null,
    },
    temporaryPassageWords: 80,
  };
  const closed = {
    ...copy,
    id: "closed-copy",
    temporaryPolicy: { ...copy.temporaryPolicy, allowed: false },
  };
  const bare = { ...copy, id: "bare-copy" } as any;
  delete bare.temporaryPolicy;
  s.retreatGroups = [copy, closed, bare];
  assert.ok(isSnapshot(s));

  const only = accessRequestChoices(s, ["retreat-copy"]);
  assert.deepEqual(only, [
    {
      id: "retreat-copy",
      name: `${copy.name} (retreat)`,
      temporaryPolicy: copy.temporaryPolicy,
      temporaryPassageWords: 80,
    },
  ]);
  // Both kinds together: the baseline group first, each named distinctly.
  assert.deepEqual(
    accessRequestChoices(s, [s.groups[0].id, "retreat-copy"]).map((g) => g.id),
    [s.groups[0].id, "retreat-copy"],
  );
  // Copies that refuse temporary access, or say nothing about it, are not offered.
  assert.deepEqual(accessRequestChoices(s, ["closed-copy", "bare-copy"]), []);
  // Unnamed groups never appear.
  assert.deepEqual(accessRequestChoices(s, ["elsewhere"]), []);

  for (const mutate of [
    (r: any) => (r.temporaryPolicy = { allowed: "yes" }),
    (r: any) => (r.temporaryPolicy.words = 5),
    (r: any) => (r.temporaryPolicy.resetDays = 0),
    (r: any) => (r.temporaryPassageWords = 3),
  ]) {
    const bad: any = structuredClone(s);
    mutate(bad.retreatGroups[0]);
    assert.equal(isSnapshot(bad), false);
  }
});
