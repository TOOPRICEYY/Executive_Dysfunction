import { test } from "node:test";
import assert from "node:assert/strict";
import { createRequire } from "node:module";
import { fileURLToPath } from "node:url";
import { buildSync } from "esbuild";
import { createElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { previewSnapshot } from "../src/preview.ts";

// Compile the real component, keeping React shared with the server renderer.
const compiled = buildSync({
  entryPoints: [fileURLToPath(new URL("../src/Settings.tsx", import.meta.url))],
  bundle: true,
  write: false,
  platform: "node",
  format: "cjs",
  packages: "external",
  jsx: "automatic",
}).outputFiles[0].text;
const componentModule = { exports: {} as any };
new Function("require", "module", "exports", compiled)(
  createRequire(import.meta.url),
  componentModule,
  componentModule.exports,
);

test("advanced controls are available only in Settings on a supporting host", () => {
  const original = Object.getOwnPropertyDescriptor(globalThis, "document");
  Object.defineProperty(globalThis, "document", {
    configurable: true,
    value: {
      documentElement: { dataset: { theme: "dark", accent: "violet" } },
    },
  });
  try {
    const snapshot = previewSnapshot();
    const render = (extra = {}) =>
      renderToStaticMarkup(
        createElement(componentModule.exports.Settings, { snapshot, ...extra }),
      );
    assert.doesNotMatch(render(), /Advanced native controls/);
    snapshot.platform = "macos";
    snapshot.capabilities.push("advancedControls");
    assert.match(render({ onAdvancedControls() {} }), /<h2>Advanced<\/h2>/);
    assert.match(
      render({ onAdvancedControls() {} }),
      /<button>Advanced native controls<\/button>/,
    );
    assert.match(
      render({ onAdvancedControls() {}, busy: true }),
      /<button disabled="">Advanced native controls<\/button>/,
    );
    assert.match(
      render(),
      /<button disabled="">Advanced native controls<\/button>/,
    );
  } finally {
    if (original) Object.defineProperty(globalThis, "document", original);
    else Reflect.deleteProperty(globalThis, "document");
  }
});
