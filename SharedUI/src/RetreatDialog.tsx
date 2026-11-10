import { useState } from "react";
import type { ChangePolicy, RetreatDraft, Snapshot } from "./contract.ts";
import { Modal, NumberField } from "./components.tsx";
import {
  fromLocalInput,
  retreatDraft,
  retreatProblem,
  type RetreatForm,
} from "./retreat-form.ts";

/**
 * Creates a retreat, or changes one that has not started. The host owns the
 * rules: it re-validates everything and a running retreat never opens here.
 */
export function RetreatDialog({
  snapshot,
  initial,
  choices,
  status,
  busy,
  error,
  onClose,
  onSubmit,
}: {
  snapshot: Snapshot;
  initial: RetreatForm;
  /** Groups to choose from; a new retreat uses the Blocking Groups. */
  choices: { id: string; name: string }[];
  /** The saved state when editing, otherwise undefined. */
  status?: "draft" | "scheduled";
  busy: boolean;
  error: string;
  onClose(): void;
  onSubmit(retreat: RetreatDraft): Promise<void>;
}) {
  const [form, setForm] = useState(initial);
  const patch = (value: Partial<RetreatForm>) =>
    setForm((old) => ({ ...old, ...value }));
  const policy = (value: Partial<ChangePolicy>) =>
    patch({ changePolicy: { ...form.changePolicy, ...value } });
  const toggle = (id: string) =>
    patch({
      groupIDs: form.groupIDs.includes(id)
        ? form.groupIDs.filter((v) => v !== id)
        : [...form.groupIDs, id],
    });
  const problem = retreatProblem(form);
  // Only a new retreat or a draft can be started from here, as natively.
  const canStart = !form.id || status === "draft";
  const startsLater =
    (Date.parse(fromLocalInput(form.start) ?? "") || 0) > Date.now();
  const details = (id: string) => {
    const g = snapshot.groups.find((v) => v.id === id);
    if (!g) return "Kept from this retreat";
    return (
      [
        g.domains.length
          ? `${g.domains.length} website${g.domains.length === 1 ? "" : "s"}`
          : "",
        g.applicationSummary ??
          (g.applications.length
            ? `${g.applications.length} app${g.applications.length === 1 ? "" : "s"}`
            : ""),
      ]
        .filter(Boolean)
        .join(" · ") || "No apps or websites on this device"
    );
  };
  return (
    <Modal
      title={form.id ? "Edit retreat" : "New retreat"}
      onClose={onClose}
      busy={busy}
    >
      <form
        onSubmit={(e) => {
          e.preventDefault();
          if (!problem) void onSubmit(retreatDraft(form));
        }}
      >
        <div className="dialog-content">
          {error && (
            <div className="banner error" role="alert">
              {error}
            </div>
          )}
          <p>
            The groups you choose are copied into this retreat, with their
            schedules and budgets, and block from its start to its end.
          </p>
          <label>
            Name
            <input
              value={form.name}
              maxLength={120}
              placeholder="News & feeds reset"
              onChange={(e) => patch({ name: e.target.value })}
            />
          </label>
          <label>
            Purpose
            <textarea
              rows={2}
              value={form.goal}
              maxLength={2000}
              placeholder="What should this make room for?"
              onChange={(e) => patch({ goal: e.target.value })}
            />
          </label>
          <div className="retreat-dates">
            <label>
              Starts
              <input
                type="datetime-local"
                value={form.start}
                onChange={(e) => patch({ start: e.target.value })}
              />
            </label>
            <label>
              Ends
              <input
                type="datetime-local"
                value={form.end}
                min={form.start || undefined}
                onChange={(e) => patch({ end: e.target.value })}
              />
            </label>
          </div>
          <fieldset>
            <legend>Blocking Groups</legend>
            {choices.map((g) => (
              <label className="check" key={g.id}>
                <input
                  type="checkbox"
                  checked={form.groupIDs.includes(g.id)}
                  onChange={() => toggle(g.id)}
                />
                <span>
                  {g.name} <small>{details(g.id)}</small>
                </span>
              </label>
            ))}
            {!choices.length && <p>Create a Blocking Group first.</p>}
          </fieldset>
          <fieldset>
            <legend>Changes and ending early</legend>
            <label>
              Retreat lock
              <select
                value={form.changePolicy.kind}
                onChange={(e) =>
                  policy({ kind: e.target.value as ChangePolicy["kind"] })
                }
              >
                {initial.changePolicy.kind === "inherited" && (
                  <option value="inherited">Use the app default</option>
                )}
                <option value="delay">Wait, then type a passage</option>
                <option value="passage">Type a passage</option>
                <option value="checkpoints">Repeated confirmations</option>
                <option value="none">No confirmation required</option>
              </select>
            </label>
            {["delay", "checkpoints"].includes(form.changePolicy.kind) && (
              <NumberField
                label="Unlock wait (days)"
                value={form.changePolicy.delayDays}
                min={0}
                max={365}
                onChange={(delayDays) => policy({ delayDays })}
              />
            )}
            {!["none", "inherited"].includes(form.changePolicy.kind) && (
              <NumberField
                label="Passage (words)"
                value={form.changePolicy.words}
                min={20}
                max={300}
                onChange={(words) => policy({ words })}
              />
            )}
            <small>
              Editing a running retreat and ending it early both follow this
              lock. The groups' own protections still apply.
            </small>
          </fieldset>
          {canStart && (
            <label className="check">
              <input
                type="checkbox"
                checked={form.startNow}
                onChange={(e) => patch({ startNow: e.target.checked })}
              />
              <span>
                {startsLater ? "Schedule it now" : "Start it now"}{" "}
                <small>
                  Otherwise it is kept as a draft. Once it starts, ending early
                  needs the lock above.
                </small>
              </span>
            </label>
          )}
          {problem && <small role="status">{problem}</small>}
        </div>
        <div className="dialog-actions">
          <button type="button" disabled={busy} onClick={onClose}>
            Cancel
          </button>
          <button className="primary" disabled={busy || !!problem}>
            {form.startNow && canStart
              ? startsLater
                ? "Schedule retreat"
                : "Start retreat"
              : status === "scheduled"
                ? "Save changes"
                : "Save draft"}
          </button>
        </div>
      </form>
    </Modal>
  );
}
