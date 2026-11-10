import { useState } from "react";
import type { AccessChoice } from "./presentation.ts";
import { Modal } from "./components.tsx";
import { temporaryPassageDescription } from "./temporary-passage.ts";

export function AccessDialog({
  group: initialGroup,
  choices,
  fixedMinutes,
  intro,
  busy,
  error,
  onClose,
  onSubmit,
}: {
  group: AccessChoice;
  /** Groups the request may apply to (a block-screen request); the first is preselected. */
  choices?: AccessChoice[];
  /** The duration the block screen already chose. */
  fixedMinutes?: number;
  intro?: string;
  busy: boolean;
  error: string;
  onClose(): void;
  onSubmit(
    minutes: number,
    reason: "conscious" | "edulgence",
    reflection: string,
    groupID: string,
  ): Promise<void>;
}) {
  const [groupID, setGroupID] = useState(initialGroup.id);
  const group = choices?.find((g) => g.id === groupID) ?? initialGroup;
  const durations = fixedMinutes
    ? [fixedMinutes]
    : [1, 5, 10, 30, 60].filter(
        (v) => v <= group.temporaryPolicy.maximumMinutes,
      );
  const [minutes, setMinutes] = useState(
    durations[0] ?? group.temporaryPolicy.maximumMinutes,
  );
  const [reason, setReason] = useState<"conscious" | "edulgence">("conscious");
  const [reflection, setReflection] = useState("");
  return (
    <Modal
      title={`Temporary access · ${group.name}`}
      onClose={onClose}
      busy={busy}
    >
      <form
        onSubmit={(e) => {
          e.preventDefault();
          void onSubmit(
            fixedMinutes ?? minutes,
            reason,
            reflection.trim(),
            group.id,
          );
        }}
      >
        <div className="dialog-content">
          {error && (
            <div className="banner error" role="alert">
              {error}
            </div>
          )}
          <p>
            {intro ??
              "This requests a timed allowance. Your device will show and verify the required passage before granting it."}
          </p>
          {choices && choices.length > 1 && (
            <label>
              Which group?
              <select
                value={groupID}
                onChange={(e) => setGroupID(e.target.value)}
              >
                {choices.map((g) => (
                  <option key={g.id} value={g.id}>
                    {g.name}
                  </option>
                ))}
              </select>
            </label>
          )}
          <label>
            For how long?
            <select
              disabled={!!fixedMinutes}
              value={fixedMinutes ?? minutes}
              onChange={(e) => setMinutes(Number(e.target.value))}
            >
              {(durations.length
                ? durations
                : [group.temporaryPolicy.maximumMinutes]
              ).map((m) => (
                <option key={m} value={m}>
                  {m === 1 ? "1 minute" : `${m} minutes`}
                </option>
              ))}
            </select>
          </label>
          <p>{temporaryPassageDescription(group)}</p>
          <fieldset>
            <legend>What brings you here?</legend>
            <label className="check">
              <input
                type="radio"
                name="reason"
                checked={reason === "conscious"}
                onChange={() => setReason("conscious")}
              />
              Conscious intervention
            </label>
            <label className="check">
              <input
                type="radio"
                name="reason"
                checked={reason === "edulgence"}
                onChange={() => setReason("edulgence")}
              />
              E-dulgance
            </label>
          </fieldset>
          <label>
            What will you do with this time, and when will you stop?
            <textarea
              required
              maxLength={280}
              value={reflection}
              onChange={(e) => setReflection(e.target.value)}
            />
            <small>
              At least four words. Saved with this temporary-access request.
            </small>
          </label>
        </div>
        <div className="dialog-actions">
          <button type="button" disabled={busy} onClick={onClose}>
            Cancel
          </button>
          <button
            className="primary"
            disabled={
              busy || reflection.trim().split(/\s+/).filter(Boolean).length < 4
            }
          >
            Continue to passage
          </button>
        </div>
      </form>
    </Modal>
  );
}
