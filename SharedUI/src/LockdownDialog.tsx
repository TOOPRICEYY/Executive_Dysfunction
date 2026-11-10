import { useState } from "react";
import type { Snapshot } from "./contract.ts";
import { Modal } from "./components.tsx";
import { when } from "./view-format.ts";

/** Hours offered for a new lockdown. The host re-validates the value. */
export const lockdownHours = [1, 4, 12, 24, 72, 168];
export const hoursLabel = (h: number) =>
  h < 24 ? `${h} ${h === 1 ? "hour" : "hours"}` : `${h / 24} ${h === 24 ? "day" : "days"}`;

export function LockdownDialog({
  snapshot,
  busy,
  error,
  onClose,
  onSubmit,
  onEnd,
}: {
  snapshot: Snapshot;
  busy: boolean;
  error: string;
  onClose(): void;
  onSubmit(groupIDs: string[], hours: number): Promise<void>;
  /** Asks the host for the passage that ends this session early. */
  onEnd(sessionID: string): void;
}) {
  const [selected, setSelected] = useState<string[]>([]);
  const [hours, setHours] = useState(4);
  const toggle = (id: string) =>
    setSelected((old) =>
      old.includes(id) ? old.filter((v) => v !== id) : [...old, id],
    );
  const target = (count: number, noun: string) =>
    count ? `${count} ${noun}${count === 1 ? "" : "s"}` : "";
  return (
    <Modal title="Start a lockdown" onClose={onClose} busy={busy}>
      <form
        onSubmit={(e) => {
          e.preventDefault();
          void onSubmit(selected, hours);
        }}
      >
        <div className="dialog-content">
          {error && (
            <div className="banner error" role="alert">
              {error}
            </div>
          )}
          {snapshot.lockdown && (
            <fieldset>
              <legend>Running now</legend>
              {snapshot.lockdown.sessions?.length ? (
                snapshot.lockdown.sessions.map((s) => (
                  <p className="lockdown-session" key={s.id}>
                    <span>
                      {s.groupNames.join(" · ") || "Lockdown"} · until{" "}
                      {when(s.endsAt)}
                    </span>
                    <button
                      type="button"
                      disabled={busy}
                      onClick={() => onEnd(s.id)}
                    >
                      End early…
                    </button>
                  </p>
                ))
              ) : (
                <p>
                  {snapshot.lockdown.groupNames.join(" · ")} · until{" "}
                  {when(snapshot.lockdown.endsAt)}
                </p>
              )}
              {snapshot.lockdown.detail && (
                <small>{snapshot.lockdown.detail}</small>
              )}
            </fieldset>
          )}
          <p>
            The groups you pick stay blocked for the whole period on all your
            devices, whatever their schedules say and whether or not they are
            switched on. Ending early needs a typed passage.
          </p>
          <fieldset>
            <legend>Which groups?</legend>
            {snapshot.groups.map((g) => {
              const targets =
                [
                  target(g.domains.length, "website"),
                  g.applicationSummary ?? target(g.applications.length, "app"),
                ]
                  .filter(Boolean)
                  .join(" · ") || "No apps or websites on this device";
              return (
                <label className="check" key={g.id}>
                  <input
                    type="checkbox"
                    checked={selected.includes(g.id)}
                    onChange={() => toggle(g.id)}
                  />
                  <span>
                    {g.name} <small>{targets}</small>
                  </span>
                </label>
              );
            })}
            {!snapshot.groups.length && (
              <p>Create a Blocking Group first.</p>
            )}
          </fieldset>
          <label>
            For how long?
            <select
              value={hours}
              onChange={(e) => setHours(Number(e.target.value))}
            >
              {lockdownHours.map((h) => (
                <option key={h} value={h}>
                  {hoursLabel(h)}
                </option>
              ))}
            </select>
          </label>
        </div>
        <div className="dialog-actions">
          <button type="button" disabled={busy} onClick={onClose}>
            Cancel
          </button>
          <button className="primary" disabled={busy || !selected.length}>
            Start lockdown
          </button>
        </div>
      </form>
    </Modal>
  );
}
