import { test } from "node:test";
import assert from "node:assert/strict";
import { createBridge } from "../src/bridge.ts";
import { isSnapshot, type RequestEnvelope } from "../src/contract.ts";
import { createPreviewAdapter, previewSnapshot } from "../src/preview.ts";
import {
  bypassCounts,
  daySegments,
  policyWarning,
  nowHeadline,
  byNow,
  lockChip,
  laneLabel,
} from "../src/presentation.ts";

test("dashboard headline respects confirmed device state and never claims preview enforcement", () => {
  const state = previewSnapshot();
  // Preview shows the fixture's own host-style summary (sample data only).
  assert.equal(nowHeadline(state), state.summary!.headline);
  state.platform = "macos";
  assert.equal(nowHeadline(state), "Enforcement is paused");
  state.enforcement.state = "unknown";
  assert.equal(nowHeadline(state), "Check device enforcement");
  state.enforcement.state = "active";
  assert.equal(nowHeadline(state), state.summary!.headline);
  delete state.summary;
  state.groups.forEach((g) => (g.status = "allowed"));
  state.groups[0].status = "blocking";
  assert.equal(nowHeadline(state), "1 group is blocking now");
  state.groups[1].status = "lockdown";
  assert.equal(nowHeadline(state), "2 groups are blocking now");
});
test("host-evaluated now state drives order, lock chips and lane labels", () => {
  const now = new Date(2026, 9, 3, 12, 0);
  const later = new Date(2026, 9, 3, 18, 0).toISOString();
  const tomorrow = new Date(2026, 9, 4, 9, 0).toISOString();
  const items = [
    {
      name: "b",
      now: { state: "upcoming" as const, changesAt: tomorrow, headline: "" },
    },
    {
      name: "a",
      now: { state: "upcoming" as const, changesAt: later, headline: "" },
    },
    { name: "c", now: { state: "blocking" as const, headline: "" } },
    { name: "d", now: { state: "off" as const, headline: "" } },
  ];
  assert.deepEqual(
    byNow(items, (i) => i.now).map((i) => i.name),
    ["c", "a", "b", "d"],
  );
  assert.equal(lockChip("delay", 3).label, "3-day lock");
  assert.equal(lockChip("checkpoints", 7).label, "Daily confirm");
  assert.equal(laneLabel(items[1].now, 60, true, now), "Later today");
  assert.equal(laneLabel(items[0].now, 60, true, now), "Done for today");
  assert.equal(laneLabel(items[0].now, 0, true, now), "Not today");
  assert.equal(laneLabel(undefined, 90, false, now), "1h 30m");
  assert.equal(laneLabel(undefined, 0, false, now), "Free");
});
test("optional host fields are validated when present", () => {
  const state = previewSnapshot();
  assert.equal(isSnapshot(state), true);
  assert.ok(state.groups.every((g) => g.now));
  assert.equal(state.schedule!.days.length, 7);
  for (const mutate of [
    (s: any) => (s.groups[0].now = { state: "nope", headline: "" }),
    (s: any) => (s.summary = { headline: 1, next: null }),
    (s: any) =>
      (s.schedule.days[0].lanes[0].intervals = [{ start: "x", end: "y" }]),
    (s: any) =>
      (s.presets = [{ id: "p", name: "P", summary: "", lock: "weird" }]),
    (s: any) => (s.groups[0].unlock = { phase: "open" }),
    (s: any) => (s.retreatGroups = [{ id: "r", name: "R" }]),
  ]) {
    const copy = structuredClone(state);
    mutate(copy);
    assert.equal(isSnapshot(copy), false);
  }
});
test("native appearance is optional but must use recognized theme and highlight tokens", () => {
  const state = previewSnapshot();
  assert.equal(isSnapshot(state), true);
  state.appearance = { theme: "dark", accent: "violet" };
  assert.equal(isSnapshot(state), true);
  state.appearance.accent = "unrecognized";
  assert.equal(isSnapshot(state), false);
});

test("contract accepts explicit fixture and rejects missing/invalid state", () => {
  assert.equal(isSnapshot(previewSnapshot()), true);
  for (const mutate of [
    (s) => delete s.enforcement,
    (s) => (s.schema = 2),
    (s) => (s.groups[0].schedule.slots[0].weekdays = [0]),
    (s) => (s.groups[0].temporaryPolicy.words = -1),
    (s) => (s.retreats[0].startsAt = "bad"),
    (s) => (s.retreats = [null]),
    (s) => (s.bypasses = [null]),
    (s) => (s.groups[0].schedule.slots = [null]),
  ]) {
    const state: any = previewSnapshot();
    mutate(state);
    assert.equal(isSnapshot(state), false);
  }
});
test("bridge correlates replies, ignores unsolicited data and surfaces rejection", async () => {
  let receive: (r: unknown) => void = () => {};
  let request: RequestEnvelope;
  const bridge = createBridge({
    post(r) {
      request = r;
    },
    subscribe(fn) {
      receive = fn;
      return () => {};
    },
  });
  const result = bridge.send({ type: "snapshot" });
  receive({
    version: 1,
    id: "unrelated",
    ok: true,
    result: { snapshot: previewSnapshot() },
  });
  receive({
    version: 1,
    id: request!.id,
    ok: true,
    result: { snapshot: previewSnapshot() },
  });
  assert.equal((await result).snapshot?.platform, "preview");
  const rejected = bridge.send({ type: "diagnostics" });
  receive({ version: 1, id: request!.id, ok: false, error: "Unsupported" });
  await assert.rejects(rejected, /Unsupported/);
  bridge.dispose();
});
test("bridge rejects incompatible snapshots without reporting success", async () => {
  let receive: (r: unknown) => void = () => {};
  const bridge = createBridge({
    post(r) {
      receive({
        version: 1,
        id: r.id,
        ok: true,
        result: { snapshot: { schema: 99 } },
      });
    },
    subscribe(fn) {
      receive = fn;
      return () => {};
    },
  });
  await assert.rejects(bridge.send({ type: "snapshot" }), /incompatible/);
  bridge.dispose();
});
test("timeout never retries a mutation", async () => {
  let posts = 0;
  const bridge = createBridge(
    {
      post() {
        posts++;
      },
      subscribe() {
        return () => {};
      },
    },
    5,
  );
  await assert.rejects(
    bridge.send({ type: "startLockdown", revision: "1" }),
    /Refresh status/,
  );
  assert.equal(posts, 1);
  bridge.dispose();
});
test("disposing bridge releases pending requests and rejects new ones", async () => {
  const bridge = createBridge({
    post() {},
    subscribe() {
      return () => {};
    },
  });
  const result = bridge.send({ type: "snapshot" });
  bridge.dispose();
  await assert.rejects(result, /closed/);
  await assert.rejects(bridge.send({ type: "snapshot" }), /closed/);
});
test("synchronous transport failure is propagated", async () => {
  const bridge = createBridge({
    post() {
      throw new Error("offline");
    },
    subscribe() {
      return () => {};
    },
  });
  await assert.rejects(bridge.send({ type: "snapshot" }), /offline/);
  bridge.dispose();
});
test("preview rejects unsupported operations and stale writes; never labels saved groups enforced", async () => {
  const adapter = createPreviewAdapter();
  const snapshot = (await adapter.send({ type: "snapshot" })).snapshot!;
  await assert.rejects(
    adapter.send({ type: "startLockdown", revision: snapshot.revision }),
    /not simulated/,
  );
  const saved = await adapter.send({
    type: "saveGroup",
    revision: snapshot.revision,
    group: snapshot.groups[0],
  });
  assert.equal(saved.snapshot?.groups[0].status, "unsupported");
  await assert.rejects(
    adapter.send({
      type: "saveGroup",
      revision: snapshot.revision,
      group: snapshot.groups[0],
    }),
    /out of date/,
  );
  snapshot.groups[0].name = "Mutated copy";
  assert.notEqual(
    (await adapter.send({ type: "snapshot" })).snapshot?.groups[0].name,
    "Mutated copy",
  );
});
test("schedule drawing wraps Sunday overnight into Monday without splitting columns", () => {
  const slot = { id: "1", weekdays: [1], startMinutes: 1380, endMinutes: 60 };
  assert.deepEqual(daySegments([slot], 1), [[1380, 1440]]);
  assert.deepEqual(daySegments([slot], 2), [[0, 60]]);
  assert.deepEqual(daySegments([slot], 3), []);
});
test("equal endpoints draw a 24-hour span; duplicate weekdays are deduplicated", () => {
  const slot = {
    id: "1",
    weekdays: [2, 2],
    startMinutes: 540,
    endMinutes: 540,
  };
  assert.deepEqual(daySegments([slot], 2), [[540, 1440]]);
  assert.deepEqual(daySegments([slot], 3), [[0, 540]]);
});
test("temporary access and general policy warning is advisory only", () => {
  const group = previewSnapshot().groups[0];
  assert.match(policyWarning(group)!, /no harder/);
  group.changePolicy.kind = "delay";
  group.changePolicy.delayDays = 3;
  assert.equal(policyWarning(group), null);
  group.changePolicy.kind = "none";
  assert.match(policyWarning(group)!, /easier/);
  group.temporaryPolicy.allowed = false;
  assert.equal(policyWarning(group), null);
});
test("history counts filter by date and group identity, not mutable name", () => {
  const event = previewSnapshot().bypasses[0];
  const counted = bypassCounts(
    [event, { ...event, id: "2", groupName: "Renamed" }],
    0,
  );
  assert.equal(counted.length, 1);
  assert.equal(counted[0].count, 2);
  assert.deepEqual(bypassCounts([event], Date.now()), []);
});
