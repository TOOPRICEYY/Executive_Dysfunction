import { test } from "node:test";
import assert from "node:assert/strict";
import { previewSnapshot } from "../src/preview.ts";
import { isSnapshot } from "../src/contract.ts";
import { temporaryPassageDescription } from "../src/temporary-passage.ts";

test("temporary access displays the host's escalated requirement without overwriting the base policy", () => {
  const state = previewSnapshot();
  const group = state.groups[0];
  group.temporaryPolicy.words = 140;
  group.temporaryPassageWords = 700;
  assert.match(temporaryPassageDescription(group), /700 words \(140-word base/);
  assert.equal(group.temporaryPolicy.words, 140);
  assert.ok(isSnapshot(state));
  group.temporaryPassageWords = 38401;
  assert.equal(isSnapshot(state), false);
  delete group.temporaryPassageWords;
  assert.match(temporaryPassageDescription(group), /Base passage: 140 words/);
  assert.doesNotMatch(
    temporaryPassageDescription(group),
    /Current requirement: 140/,
  );
});

import {
  accessTimingDescription,
  minutesText,
  waitMinutes,
} from "../src/temporary-passage.ts";
import {
  byNow,
  groupNow,
  isBlockingState,
  laneLabel,
  shownNow,
} from "../src/presentation.ts";

test("the wait is said plainly before the person commits", () => {
  const policy = previewSnapshot().groups[0].temporaryPolicy;
  assert.equal(accessTimingDescription(policy, 30), "");
  policy.waitMinutes = 10;
  assert.equal(
    accessTimingDescription(policy, 30),
    "Access opens 10 minutes after you finish the passage, then lasts 30 minutes. Blocking continues until then.",
  );
  const group = { ...previewSnapshot().groups[0], temporaryPolicy: policy };
  assert.match(
    temporaryPassageDescription(group, 30),
    /^Access opens 10 minutes after you finish the passage, then lasts 30 minutes\. .*Base passage|^Access opens 10 minutes after you finish the passage, then lasts 30 minutes\. .*requirement/,
  );
  policy.waitMinutes = 90;
  assert.match(accessTimingDescription(policy, 1), /1 hour 30 minutes after .* lasts 1 minute\./);
  assert.equal(minutesText(60), "1 hour");
  assert.equal(minutesText(1), "1 minute");
  delete policy.waitMinutes;
  assert.equal(waitMinutes(policy), 0, "an older host's policy has no wait");
});

test("the contract validates waitMinutes, the waiting state and accessOpensAt", () => {
  const state = previewSnapshot();
  const g = state.groups[0];
  assert.ok(isSnapshot(state), "absent waitMinutes stays valid");
  for (const ok of [0, 10, 1440]) {
    g.temporaryPolicy.waitMinutes = ok;
    assert.ok(isSnapshot(state), `wait ${ok}`);
  }
  for (const bad of [-1, 1441, 1.5, "10" as unknown as number]) {
    g.temporaryPolicy.waitMinutes = bad;
    assert.equal(isSnapshot(state), false, `wait ${bad}`);
  }
  g.temporaryPolicy.waitMinutes = 10;
  const opens = new Date(Date.now() + 10 * 60_000).toISOString();
  g.accessOpensAt = opens;
  g.status = "blocking";
  g.now = {
    state: "waiting",
    changesAt: opens,
    headline: "Access opens at 3:10 PM · blocking until then",
  };
  assert.ok(isSnapshot(state));
  g.accessOpensAt = "soon";
  assert.equal(isSnapshot(state), false);
});

test("a waiting group reads as blocking, never as allowed", () => {
  const g = previewSnapshot().groups[0];
  const opens = new Date(Date.now() + 10 * 60_000).toISOString();
  g.status = "blocking";
  g.now = { state: "waiting", changesAt: opens, headline: "Access opens at 3:10 PM · blocking until then" };
  assert.ok(isBlockingState(groupNow(g).state));
  assert.equal(laneLabel(g.now, 60, true, new Date()), "Blocking");
  assert.equal(shownNow(g.now, true).headline, g.now.headline);
  // Unconfirmed enforcement must not claim the block ends when access opens.
  assert.equal(shownNow(g.now, false).headline, "Scheduled now · not enforced");
  const idle = { ...g, id: "idle", name: "A idle", now: { state: "idle" as const, headline: "No blocks" } };
  assert.equal(byNow([idle, g], (x) => x.now!)[0].id, g.id);
});
