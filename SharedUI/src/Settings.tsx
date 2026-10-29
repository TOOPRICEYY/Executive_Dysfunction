import { useState, useEffect } from "react";
import type { Snapshot } from "./contract.ts";

export function Settings({
  snapshot,
  onDiagnostics,
  onAdvancedControls,
  busy = false,
}: {
  snapshot: Snapshot;
  onDiagnostics?: () => void;
  onAdvancedControls?: () => void;
  busy?: boolean;
}) {
  const { theme, accent, choose } = useAppearance();
  return (
    <>
      <section className="panel settings">
        <h2>Appearance</h2>
        <p>Choose the interface theme and highlight color.</p>
        <label>
          Theme
          <select
            value={theme}
            onChange={(e) => {
              choose("theme", e.target.value);
            }}
          >
            {!snapshot.capabilities.includes("appearance") && (
              <option value="system">Follow system</option>
            )}
            <option value="light">Light</option>
            <option value="dark">Dark</option>
          </select>
        </label>
        <label>
          Accent
          <select
            value={accent}
            onChange={(e) => {
              choose("accent", e.target.value);
            }}
          >
            <option value="themeDefault">Theme default</option>
            <option value="yellow">Signal yellow</option>
            <option value="green">Phosphor green</option>
            <option value="blue">Electric blue</option>
            <option value="orange">Warning orange</option>
            <option value="magenta">Hot magenta</option>
            <option value="violet">Terminal violet</option>
          </select>
        </label>
      </section>
      <section className="panel">
        <h2>Device connection</h2>
        <p>{snapshot.enforcement.detail}</p>
        <p>{snapshot.sync.detail}</p>
        <button disabled={!onDiagnostics} onClick={onDiagnostics}>
          Open diagnostics
        </button>
      </section>
      {snapshot.capabilities.includes("advancedControls") && (
        <section className="panel">
          <h2>Advanced</h2>
          <p>Open the native editors and platform-specific controls.</p>
          <button
            disabled={busy || !onAdvancedControls}
            onClick={onAdvancedControls}
          >
            Advanced native controls
          </button>
        </section>
      )}
    </>
  );
}
export function useAppearance() {
  const [theme, setTheme] = useState(
    document.documentElement.dataset.theme ?? readPreference("theme", "light"),
  );
  const [accent, setAccent] = useState(
    document.documentElement.dataset.accent ??
      readPreference("accent", "themeDefault"),
  );
  useEffect(() => {
    const update = () => {
      setTheme(document.documentElement.dataset.theme ?? "light");
      setAccent(document.documentElement.dataset.accent ?? "themeDefault");
    };
    window.addEventListener("holdfast-appearance", update);
    return () => window.removeEventListener("holdfast-appearance", update);
  }, []);
  return {
    theme,
    accent,
    choose: (key: "theme" | "accent", value: string) => {
      try {
        localStorage.setItem(`holdfast.ui.${key}`, value);
      } catch {
        /* Keep session appearance. */
      }
      document.documentElement.dataset[key] = value;
      window.dispatchEvent(
        new CustomEvent("holdfast-appearance", { detail: { key, value } }),
      );
    },
  };
}
export function ThemeSwitch() {
  const { theme, choose } = useAppearance();
  return (
    <div className="theme-switch">
      <span>Theme</span>
      <div>
        {["light", "dark"].map((value) => (
          <button
            key={value}
            aria-pressed={theme === value}
            onClick={() => choose("theme", value)}
          >
            {value}
          </button>
        ))}
      </div>
    </div>
  );
}
export function readPreference(key: string, fallback: string) {
  try {
    return localStorage.getItem(`holdfast.ui.${key}`) ?? fallback;
  } catch {
    return fallback;
  }
}
