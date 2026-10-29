import { useState } from "react";
import type { Group } from "./contract.ts";
import { Modal } from "./components.tsx";
import { temporaryPassageDescription } from "./temporary-passage.ts";

export function AccessDialog({
  group,
  busy,
  error,
  onClose,
  onSubmit,
}: {
  group: Group;
  busy: boolean;
  error: string;
  onClose(): void;
  onSubmit(
    minutes: number,
    reason: "conscious" | "edulgence",
    reflection: string,
  ): Promise<void>;
}) {
  const durations = [10, 30, 60].filter(
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
          void onSubmit(minutes, reason, reflection.trim());
        }}
      >
        <div className="dialog-content">
          {error && (
            <div className="banner error" role="alert">
              {error}
            </div>
          )}
          <p>
            This requests a timed allowance. Your device will show and verify
            the required passage before granting it.
          </p>
          <label>
            For how long?
            <select
              value={minutes}
              onChange={(e) => setMinutes(Number(e.target.value))}
            >
              {(durations.length
                ? durations
                : [group.temporaryPolicy.maximumMinutes]
              ).map((m) => (
                <option key={m} value={m}>
                  {m} minutes
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
