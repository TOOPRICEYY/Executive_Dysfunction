import test from "node:test";
import assert from "node:assert/strict";
import {
  fromLocalInput,
  newRetreatForm,
  retreatDraft,
  retreatFormFrom,
  retreatProblem,
  toLocalInput,
} from "../src/retreat-form.ts";
import { isSnapshot } from "../src/contract.ts";
import { previewSnapshot } from "../src/preview.ts";

test("local date inputs convert to ISO UTC and back, whatever the time zone", () => {
  const local = new Date(2026, 10, 10, 9, 30);
  assert.equal(
    fromLocalInput("2026-11-10T09:30"),
    local.toISOString().replace(".000Z", "Z"),
  );
  assert.equal(
    toLocalInput(fromLocalInput("2026-11-10T09:30")!),
    "2026-11-10T09:30",
  );
  assert.match(
    fromLocalInput("2026-11-10T09:30")!,
    /^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$/,
  );
});

test("incomplete or impossible dates are refused, not rolled over", () => {
  for (const bad of [
    "",
    "2026-11-10",
    "2026-02-31T10:00",
    "2026-11-10T25:00",
    "10/11/2026 09:30",
    "2026-11-10T09:30Z",
  ])
    assert.equal(fromLocalInput(bad), null, bad);
  assert.equal(toLocalInput("not a date"), "");
});

test("a retreat needs a name, a group and an end after its start", () => {
  const form = newRetreatForm(new Date(2026, 10, 10, 9, 30, 15));
  assert.equal(form.start, "2026-11-10T09:30");
  assert.equal(form.end, "2026-12-10T09:30");
  assert.equal(retreatProblem(form), "Name the retreat.");
  form.name = "  Reset  ";
  assert.equal(retreatProblem(form), "Choose at least one Blocking Group.");
  form.groupIDs = ["g"];
  assert.equal(retreatProblem(form), "");
  assert.match(
    retreatProblem({ ...form, end: form.start }),
    /end after it starts/,
  );
  assert.match(retreatProblem({ ...form, end: "" }), /starts and ends/);
  assert.match(
    retreatProblem({
      ...form,
      changePolicy: { kind: "passage", words: 5, delayDays: 0 },
    }),
    /20 to 300/,
  );
  assert.equal(
    retreatProblem({
      ...form,
      changePolicy: { kind: "none", words: 5, delayDays: 0 },
    }),
    "",
  );
});

test("the saved draft is trimmed, in UTC and carries a wait only for waiting locks", () => {
  const form = {
    ...newRetreatForm(new Date(2026, 10, 10, 9, 30)),
    name: " Reset ",
    goal: " Read ",
    groupIDs: ["a", "b"],
  };
  const draft = retreatDraft({
    ...form,
    changePolicy: { kind: "passage", words: 60, delayDays: 3 },
  });
  assert.deepEqual(draft, {
    name: "Reset",
    goal: "Read",
    startsAt: fromLocalInput(form.start),
    endsAt: fromLocalInput(form.end),
    groupIDs: ["a", "b"],
    changePolicy: { kind: "passage", words: 60, delayDays: 0 },
    startNow: false,
  });
  assert.equal("id" in draft, false);
  assert.equal(retreatDraft({ ...form, id: "r1" }).id, "r1");
  assert.equal(retreatDraft(form).changePolicy.delayDays, 3);
});

test("an editable retreat opens on what is saved", () => {
  const form = retreatFormFrom({
    id: "r1",
    name: "Reset",
    startsAt: "2026-11-10T09:30:00Z",
    endsAt: "2026-11-12T09:30:00Z",
    state: "scheduled",
    version: 2,
    groupNames: ["News"],
    changePolicyLabel: "passageOnly",
    canRequestEnd: false,
    canEdit: true,
    goal: "Read",
    changePolicy: { kind: "passage", words: 80, delayDays: 0 },
    groupIDs: ["copy"],
    groupChoices: [{ id: "copy", name: "News" }],
  });
  assert.equal(form.id, "r1");
  assert.equal(form.goal, "Read");
  assert.deepEqual(form.groupIDs, ["copy"]);
  assert.equal(form.changePolicy.words, 80);
  assert.equal(fromLocalInput(form.start), "2026-11-10T09:30:00Z");
  assert.equal(form.startNow, false);
});

test("the contract checks the optional retreat editing fields", () => {
  const base: any = previewSnapshot();
  assert.ok(base.retreats.length);
  const ok = structuredClone(base);
  Object.assign(ok.retreats[0], {
    canEdit: true,
    goal: "",
    changePolicy: { kind: "delay", words: 40, delayDays: 3 },
    groupIDs: ["x"],
    groupChoices: [{ id: "x", name: "X" }],
  });
  assert.equal(isSnapshot(ok), true);
  for (const mutate of [
    (r: any) => (r.canEdit = "yes"),
    (r: any) => (r.goal = 3),
    (r: any) => (r.changePolicy = { kind: "delay", words: 5, delayDays: 3 }),
    (r: any) => (r.changePolicy = { kind: "forever", words: 40, delayDays: 3 }),
    (r: any) => (r.groupIDs = [1]),
    (r: any) => (r.groupChoices = [{ id: "x" }]),
    (r: any) => (r.groupChoices = [null]),
  ]) {
    const copy = structuredClone(ok);
    mutate(copy.retreats[0]);
    assert.equal(isSnapshot(copy), false);
  }
});

test("an unchanged date is sent back exactly as saved, seconds included", () => {
  // Regression: natively created retreats keep seconds; re-deriving the end
  // from the minute-only input moved a running retreat's end earlier, and the
  // host refused a plain rename as shortening it.
  const retreat = {
    id: "r1",
    name: "Reset",
    startsAt: "2026-11-10T09:30:42Z",
    endsAt: "2026-12-10T09:30:42Z",
    state: "active" as const,
    version: 1,
    groupNames: ["News"],
    changePolicyLabel: "delayed",
    canRequestEnd: true,
    canEdit: true,
    goal: "",
    changePolicy: { kind: "delay" as const, words: 40, delayDays: 3 },
    groupIDs: ["copy"],
    groupChoices: [{ id: "copy", name: "News" }],
  };
  const form = retreatFormFrom(retreat);
  const renamed = retreatDraft({ ...form, name: "Reset, renamed" });
  assert.equal(renamed.startsAt, retreat.startsAt);
  assert.equal(renamed.endsAt, retreat.endsAt);
  assert.equal(retreatProblem(form), "");

  // A field the person did change is sent as typed (whole minutes).
  const later = new Date(2026, 11, 20, 18, 0);
  const extended = retreatDraft({
    ...form,
    end: toLocalInput(later.toISOString()),
  });
  assert.equal(extended.endsAt, later.toISOString().replace(".000Z", "Z"));
  assert.equal(extended.startsAt, retreat.startsAt);
  // Changing it and changing it back is unchanged again.
  assert.equal(
    retreatDraft({ ...form, end: toLocalInput(retreat.endsAt) }).endsAt,
    retreat.endsAt,
  );
  // A new retreat has nothing saved to keep.
  const fresh = newRetreatForm(new Date(2026, 10, 10, 9, 30, 15));
  assert.equal(fresh.saved, undefined);
  assert.equal(
    retreatDraft({ ...fresh, name: "x", groupIDs: ["g"] }).endsAt,
    fromLocalInput(fresh.end),
  );
});
