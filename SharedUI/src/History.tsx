import { useState } from "react";
import type { Snapshot } from "./contract.ts";
import { Modal } from "./components.tsx";
import { when, duration } from "./view-format.ts";

export function History({
  snapshot,
  initialGroup,
  onClose,
}: {
  snapshot: Snapshot;
  initialGroup: string;
  onClose(): void;
}) {
  const [group, setGroup] = useState(initialGroup),
    [range, setRange] = useState(30);
  const events = snapshot.bypasses.filter(
    (b) =>
      (group === "all" || b.groupID === group) &&
      Date.parse(b.startedAt) >= Date.now() - range * 86_400_000,
  );
  const groupNames = new Map([
    ...snapshot.groups.map((g) => [g.id, g.name] as const),
    ...snapshot.bypasses.map((b) => [b.groupID, b.groupName] as const),
  ]);
  return (
    <Modal title="Temporary access history" onClose={onClose} wide>
      <div className="dialog-content">
        <div className="time-row">
          <label>
            Blocking group
            <select value={group} onChange={(e) => setGroup(e.target.value)}>
              <option value="all">All groups</option>
              {[...groupNames].map(([id, name]) => (
                <option value={id} key={id}>
                  {name}
                </option>
              ))}
            </select>
          </label>
          <label>
            Time range
            <select
              value={range}
              onChange={(e) => setRange(Number(e.target.value))}
            >
              {[7, 30, 90, 365].map((d) => (
                <option value={d} key={d}>
                  Last {d} days
                </option>
              ))}
            </select>
          </label>
        </div>
        <p>
          {events.length} successful grants · this device’s available history
        </p>
        {events
          .sort((a, b) => Date.parse(b.startedAt) - Date.parse(a.startedAt))
          .map((b) => (
            <article className="list-row" key={b.id}>
              <div>
                <strong>{b.groupName}</strong>
                <p>
                  {when(b.startedAt)} — {duration(b.endsAt)}
                </p>
              </div>
              <span>
                {b.reason === "conscious"
                  ? "Conscious intervention"
                  : b.reason === "edulgence"
                    ? "E-dulgance"
                    : "Intent not recorded"}
              </span>
            </article>
          ))}
        {!events.length && <p>No grants in this range.</p>}
      </div>
    </Modal>
  );
}
