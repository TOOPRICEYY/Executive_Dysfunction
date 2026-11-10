import { useState, useEffect } from "react";
import type {
  AppLockSettings,
  Capability,
  Command,
  Reply,
  Snapshot,
} from "./contract.ts";
import { ConfirmDialog, NumberField, UnlockCard } from "./components.tsx";
import { appLockProblem } from "./controls.ts";

type Send = (command: Command) => Promise<Reply | null>;

/**
 * Device settings. Every protection shown here is decided on the host: these
 * controls ask, and the host refuses anything a lock does not allow.
 */
export function Settings({
  snapshot,
  onDiagnostics,
  send,
  busy = false,
}: {
  snapshot: Snapshot;
  onDiagnostics?: () => void;
  /** Sends a command; without it the page is read-only. */
  send?: Send;
  busy?: boolean;
}) {
  const { theme, accent, choose } = useAppearance();
  const supports = (name: Capability) => snapshot.capabilities.includes(name);
  const ios = snapshot.platform === "ios";
  const protection = supports("protection") ? snapshot.protection : undefined;
  const [confirming, setConfirming] = useState<
    null | "antiUninstall" | "resetScreenTime" | "clearTrace"
  >(null);
  const revision = snapshot.revision;
  return (
    <>
      <section className="panel settings">
        <h2>Device connection</h2>
        {ios && (
          <p>
            <strong>{snapshot.enforcement.title}</strong>
          </p>
        )}
        <p>{snapshot.enforcement.detail}</p>
        <p>{snapshot.sync.detail}</p>
        {protection?.pendingSync && (
          <p className="banner warning">
            Changes from another device that would weaken, mix or remove a
            locked group wait here until that group&apos;s unlock is complete.
            Sync again afterwards to apply them.
          </p>
        )}
        <div className="actions">
          {ios &&
            !snapshot.enforcementEnabled &&
            supports("enforcementControl") && (
              <button
                className="primary"
                disabled={busy || !send}
                onClick={() =>
                  void send?.({
                    type: "setEnforcement",
                    revision,
                    enabled: true,
                  })
                }
              >
                Allow Screen Time access
              </button>
            )}
          {supports("syncNow") && (
            <button
              disabled={busy || !send}
              onClick={() => void send?.({ type: "syncNow" })}
            >
              Sync now
            </button>
          )}
          <button disabled={!onDiagnostics} onClick={onDiagnostics}>
            Open diagnostics
          </button>
        </div>
      </section>
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
            {!supports("appearance") && (
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
      {protection && (
        <section
          className="panel settings"
          aria-labelledby="protection-heading"
        >
          <h2 id="protection-heading">Protection</h2>
          {protection.antiUninstall && (
            <div>
              <label className="check">
                <input
                  type="checkbox"
                  checked={protection.antiUninstall.on}
                  disabled={busy || !send}
                  onChange={(e) =>
                    e.target.checked
                      ? setConfirming("antiUninstall")
                      : void send?.({
                          type: "setAntiUninstall",
                          revision,
                          enabled: false,
                        })
                  }
                />
                Prevent app deletion
              </label>
              <small>
                Uses Apple&apos;s setting that stops any app being deleted.
                While a lock holds, it stays on until that lock is unlocked.
              </small>
            </div>
          )}
          {protection.appLock && (
            <AppLockForm
              // A saved change comes back from the host and restarts the form.
              key={JSON.stringify({ ...protection.appLock, unlock: undefined })}
              lock={protection.appLock}
              busy={busy}
              send={send}
              revision={revision}
            />
          )}
          {ios && (
            <div>
              <h3>Recovery</h3>
              <p>
                Use this when something is still blocked and the diagnostic
                report accounts for no shield.
              </p>
              <button
                className="danger"
                disabled={busy || !send}
                onClick={() => setConfirming("resetScreenTime")}
              >
                Reset Screen Time restrictions…
              </button>
            </div>
          )}
        </section>
      )}
      {supports("debugTrace") && snapshot.debugTrace && (
        <section className="panel settings">
          <h2>Debug trace</h2>
          <p>
            A limited technical timeline to help diagnose app and web-filter
            issues. It does not record websites, URLs, page content, network
            payloads or app identities.
          </p>
          <label className="check">
            <input
              type="checkbox"
              checked={snapshot.debugTrace.recording}
              disabled={busy || !send}
              onChange={(e) =>
                void send?.({
                  type: "setDebugTrace",
                  enabled: e.target.checked,
                })
              }
            />
            Record debug trace
          </label>
          <div className="actions">
            <button
              disabled={busy || !send}
              onClick={() => void send?.({ type: "exportDebugTrace" })}
            >
              Export trace…
            </button>
            <button
              disabled={busy || !send}
              onClick={() => setConfirming("clearTrace")}
            >
              Clear trace
            </button>
          </div>
        </section>
      )}
      {ios && (
        <section className="panel">
          <h2>Privacy & limits</h2>
          <p>
            Apple exposes Screen Time selections as opaque tokens. Website
            classification applies only to domains you enter and runs on this
            device.
          </p>
          <p>
            If Screen Time access is revoked, enforcement stops. An app cannot
            install a restriction that outlives it.
          </p>
        </section>
      )}
      {confirming === "antiUninstall" && (
        <ConfirmDialog
          title="Prevent all app deletion?"
          message="Apple's setting prevents deleting any app, including Holdfast. Screen Time access can still be revoked in iOS Settings."
          confirm="Turn on"
          busy={busy}
          onCancel={() => setConfirming(null)}
          onConfirm={async () => {
            setConfirming(null);
            await send?.({ type: "setAntiUninstall", revision, enabled: true });
          }}
        />
      )}
      {confirming === "resetScreenTime" && (
        <ConfirmDialog
          title="Clear all restrictions?"
          message="This revokes Screen Time access, which discards every restriction Holdfast holds, including ones it can no longer identify, then asks for access again and reapplies your schedules. Nothing is enforced until you grant access again. Your chosen apps stay on this device, but check that each group still blocks during its next window."
          confirm="Clear restrictions"
          danger
          busy={busy}
          onCancel={() => setConfirming(null)}
          onConfirm={async () => {
            setConfirming(null);
            await send?.({ type: "resetScreenTime", revision });
          }}
        />
      )}
      {confirming === "clearTrace" && (
        <ConfirmDialog
          title="Clear the diagnostic trace?"
          message="Every recorded event is deleted. Recording keeps its current setting."
          confirm="Clear trace"
          danger
          busy={busy}
          onCancel={() => setConfirming(null)}
          onConfirm={async () => {
            setConfirming(null);
            await send?.({ type: "clearDebugTrace" });
          }}
        />
      )}
    </>
  );
}

/** App-wide change protection: its settings, then its unlock. */
function AppLockForm({
  lock,
  busy,
  send,
  revision,
}: {
  lock: NonNullable<NonNullable<Snapshot["protection"]>["appLock"]>;
  busy: boolean;
  send?: Send;
  revision: string;
}) {
  const { unlock, ...saved } = lock;
  const [draft, setDraft] = useState<AppLockSettings>(saved);
  const patch = (v: Partial<AppLockSettings>) =>
    setDraft((d) => ({ ...d, ...v }));
  const problem = appLockProblem(draft);
  const changed = JSON.stringify(draft) !== JSON.stringify(saved);
  return (
    <form
      className="settings"
      onSubmit={(e) => {
        e.preventDefault();
        if (!problem && changed)
          void send?.({ type: "saveAppLock", revision, settings: draft });
      }}
    >
      <h3>App-wide change protection</h3>
      <p>
        Once on, groups, app-deletion protection and this protection itself
        cannot be weakened without completing an unlock. Adding or tightening
        protection stays available.
      </p>
      <fieldset disabled={busy || !send}>
        <label className="check">
          <input
            type="checkbox"
            checked={draft.enabled}
            onChange={(e) => patch({ enabled: e.target.checked })}
          />
          Turn on change protection
        </label>
        <NumberField
          label="Unlock wait (days)"
          value={draft.unlockDelayDays}
          min={0}
          max={365}
          onChange={(unlockDelayDays) => patch({ unlockDelayDays })}
        />
        <label className="check">
          <input
            type="checkbox"
            checked={draft.repeatConfirmations}
            onChange={(e) => patch({ repeatConfirmations: e.target.checked })}
          />
          Require daily typed confirmations
        </label>
        <NumberField
          label="Passage length (words)"
          value={draft.passageWordCount}
          min={20}
          max={300}
          onChange={(passageWordCount) => patch({ passageWordCount })}
        />
        {draft.repeatConfirmations && (
          <NumberField
            label="Checkpoint window (hours)"
            value={draft.confirmationWindowHours}
            min={1}
            max={48}
            onChange={(confirmationWindowHours) =>
              patch({ confirmationWindowHours })
            }
          />
        )}
        <NumberField
          label="Editing window (hours)"
          value={draft.editWindowHours}
          min={1}
          max={72}
          onChange={(editWindowHours) => patch({ editWindowHours })}
        />
      </fieldset>
      {problem && <small role="status">{problem}</small>}
      <div className="actions">
        <button
          className="primary"
          disabled={busy || !send || !!problem || !changed}
        >
          Save change protection
        </button>
      </div>
      {saved.enabled && (
        <UnlockCard
          unlock={unlock}
          detail={`Unlocking needs a ${saved.passageWordCount}-word passage, then ${saved.unlockDelayDays} full day(s)${saved.repeatConfirmations ? " with a passage at each daily checkpoint" : ""}. Editing then stays open for ${saved.editWindowHours} hour(s).`}
          busy={busy}
          onRequest={
            send
              ? () => void send({ type: "requestAppUnlock", revision })
              : undefined
          }
          onCancel={
            send
              ? () => void send({ type: "cancelAppUnlock", revision })
              : undefined
          }
        />
      )}
    </form>
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
