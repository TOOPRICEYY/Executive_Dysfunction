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
  // React stays shared with the server renderer; everything else is bundled.
  external: ["react", "react-dom", "react/jsx-runtime"],
  jsx: "automatic",
}).outputFiles[0].text;
const componentModule = { exports: {} as any };
new Function("require", "module", "exports", compiled)(
  createRequire(import.meta.url),
  componentModule,
  componentModule.exports,
);

test("settings own what the native settings held, and only what the host advertises", () => {
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
    // The native window is retired: no entry point, whatever a host says.
    (snapshot.capabilities as string[]).push("advancedControls");
    assert.doesNotMatch(render(), /Advanced/);
    assert.doesNotMatch(render(), /Protection|Debug trace|Sync now/);

    snapshot.platform = "ios";
    snapshot.enforcementEnabled = false;
    snapshot.capabilities.push("protection", "syncNow", "enforcementControl");
    snapshot.protection = {
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
      pendingSync: true,
    };
    const ios = render({ send: async () => null });
    assert.match(ios, /Allow Screen Time access/);
    assert.match(ios, /<button>Sync now<\/button>/);
    assert.match(ios, /Prevent app deletion/);
    assert.match(ios, /App-wide change protection/);
    assert.match(ios, /Start unlock…/);
    assert.match(ios, /wait here until that group/);
    assert.match(ios, /Reset Screen Time restrictions…/);
    // Without a way to send, nothing on the page can act.
    assert.match(render(), /<button disabled="">Sync now<\/button>/);

    snapshot.platform = "macos";
    delete snapshot.protection;
    snapshot.capabilities = snapshot.capabilities.filter(
      (c) => c !== "protection",
    );
    snapshot.capabilities.push("debugTrace");
    snapshot.debugTrace = { recording: true };
    const mac = render({ send: async () => null });
    assert.match(mac, /Debug trace/);
    assert.match(mac, /Export trace…/);
    assert.doesNotMatch(mac, /Prevent app deletion|Reset Screen Time/);
  } finally {
    if (original) Object.defineProperty(globalThis, "document", original);
    else Reflect.deleteProperty(globalThis, "document");
  }
});
