import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

// iOS WebKit zooms the page when a form field under 16px gains focus. The
// shared screens use 13px type, so the viewport must cap the scale at 1 or
// every text field zooms the iPhone app past its right edge.
test("viewport stops iOS from zooming focused text fields", () => {
  const html = readFileSync(new URL("../index.html", import.meta.url), "utf8");
  const meta = html.match(/<meta\s+name="viewport"\s+content="([^"]*)"/);
  assert.ok(meta, "index.html declares a viewport meta tag");
  const content = meta[1].split(",").map((part) => part.trim());
  assert.ok(content.includes("width=device-width"));
  assert.ok(content.includes("initial-scale=1"));
  assert.ok(content.includes("maximum-scale=1"));
});
