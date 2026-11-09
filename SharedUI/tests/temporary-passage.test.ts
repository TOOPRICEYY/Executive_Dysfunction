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
