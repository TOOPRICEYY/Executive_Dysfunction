import { useState } from "react";
import type { LockdownLock, Snapshot } from "./contract.ts";
import { Modal, NumberField } from "./components.tsx";
import { lockdownLock, lockdownLockProblem } from "./controls.ts";
import { when } from "./view-format.ts";

/** Hours offered for a new lockdown. The host re-validates the value. */
export const lockdownHours = [1, 4, 12, 24, 72, 168];
export const hoursLabel = (h: number) =>
  h < 24
    ? `${h} ${h === 1 ? "hour" : "hours"}`
    : `${h / 24} ${h === 24 ? "day" : "days"}`;

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
  /** `lock` only when the host offers `lockdownOptions`. */
  onSubmit(
    groupIDs: string[],
    hours: number,
    lock?: LockdownLock,
  ): Promise<void>;
  /** Asks the host for the passage that ends this session early. */
  onEnd(sessionID: string): void;
}) {
  const [selected, setSelected] = useState<string[]>([]);
  const options = snapshot.lockdownOptions;
  const offered = options?.hours ?? lockdownHours;
  // The Mac lockdown window opens on three days when it is offered.
  const [hours, setHours] = useState(
    offered.includes(options ? 72 : 4) ? (options ? 72 : 4) : offered[0],
  );
  const [lock, setLock] = useState<LockdownLock>({
    kind: "passage",
    words: 80,
    delayDays: 1,
  });
  const lockProblem = options ? lockdownLockProblem(lock) : "";
  const lockNames = {
    passage: "Type a passage",
    delay: "Wait, then type a passage",
    checkpoints: "Repeated confirmations",
  };
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
          if (lockProblem) return;
          void onSubmit(
            selected,
            hours,
            options ? lockdownLock(lock) : undefined,
          );
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
            {!snapshot.groups.length && <p>Create a Blocking Group first.</p>}
          </fieldset>
          <label>
            For how long?
            <select
              value={hours}
              onChange={(e) => setHours(Number(e.target.value))}
            >
              {offered.map((h) => (
                <option key={h} value={h}>
                  {hoursLabel(h)}
                </option>
              ))}
            </select>
          </label>
          {options && (
            <fieldset>
              <legend>Ending early</legend>
              <label>
                Lock mode
                <select
                  value={lock.kind}
                  onChange={(e) =>
                    setLock({
                      ...lock,
                      kind: e.target.value as LockdownLock["kind"],
                    })
                  }
                >
                  {options.locks.map((k) => (
                    <option key={k} value={k}>
                      {lockNames[k]}
                    </option>
                  ))}
                </select>
              </label>
              <NumberField
                label="Passage length (words)"
                value={lock.words}
                min={20}
                max={300}
                onChange={(words) => setLock({ ...lock, words })}
              />
              {lock.kind !== "passage" && (
                <NumberField
                  label="Extra delay before early exit (days)"
                  value={lock.delayDays}
                  min={0}
                  max={30}
                  onChange={(delayDays) => setLock({ ...lock, delayDays })}
                />
              )}
              {lockProblem && <small role="status">{lockProblem}</small>}
            </fieldset>
          )}
        </div>
        <div className="dialog-actions">
          <button type="button" disabled={busy} onClick={onClose}>
            Cancel
          </button>
          <button
            className="primary"
            disabled={busy || !selected.length || !!lockProblem}
          >
            Start lockdown
          </button>
        </div>
      </form>
    </Modal>
  );
}
