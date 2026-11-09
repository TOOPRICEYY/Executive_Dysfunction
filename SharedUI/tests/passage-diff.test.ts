import { test } from "node:test";
import assert from "node:assert/strict";
import { passageDiff } from "../src/passage-diff.ts";
test("passage comparison preserves alignment after missing and extra words", () => {
  const tokens = passageDiff(
    "river stray flows home",
    "river quietly flows home",
  );
  assert.deepEqual(
    tokens.map((t) => t.kind),
    ["matched", "incorrect", "missing", "matched", "matched"],
  );
  assert.ok(
    passageDiff("  RIVER\nflows  ", "river flows").every(
      (t) => t.kind === "matched",
    ),
  );
});
test("maximum backoff passage uses bounded comparison and keeps later words aligned", () => {
  const words = Array.from({ length: 38400 }, (_, i) => `word${i}`);
  const typed = words.filter((_, i) => i !== 100).join(" ");
  const tokens = passageDiff(typed, words.join(" "));
  assert.equal(tokens.filter((t) => t.kind === "matched").length, 38399);
  assert.deepEqual(
    tokens.filter((t) => t.kind === "missing"),
    [{ text: "word100", kind: "missing" }],
  );
});
