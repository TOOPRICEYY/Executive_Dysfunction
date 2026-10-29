import type React from "react";
import { useEffect, useRef, useId } from "react";
import type { Group } from "./contract.ts";
import { clock, days, daySegments } from "./presentation.ts";
import { labels, duration } from "./view-format.ts";

export function SectionHeading({
  title,
  detail,
  action,
}: {
  title: string;
  detail?: string;
  action?: React.ReactNode;
}) {
  return (
    <div className="section-heading">
      <div>
        <h2>{title}</h2>
        {detail && <p>{detail}</p>}
      </div>
      {action}
    </div>
  );
}
export function Empty({ title, detail }: { title: string; detail: string }) {
  return (
    <section className="empty">
      <h2>{title}</h2>
      <p>{detail}</p>
    </section>
  );
}
export function ScheduleStrip({ group }: { group: Group }) {
  return (
    <div
      className="schedule-strip"
      aria-label={`${group.schedule.mode === "allow" ? "Allowance" : "Blocking"} windows by day`}
    >
      {days.map((day) => (
        <div key={day.id}>
          <span>{day.name}</span>
          <div className="day-track">
            {daySegments(group.schedule.slots, day.id).map(
              ([start, end], i) => (
                <i
                  key={i}
                  style={{
                    left: `${(start / 1440) * 100}%`,
                    width: `${((end - start) / 1440) * 100}%`,
                  }}
                  title={`${day.name} ${clock(start)}–${clock(end)}`}
                />
              ),
            )}
          </div>
        </div>
      ))}
    </div>
  );
}
export function GroupCard({
  group: g,
  onEdit,
  onAccess,
  onResume,
}: {
  group: Group;
  onEdit(): void;
  onAccess?: () => void;
  onResume?: () => void;
}) {
  return (
    <article className={`group-card panel status-${g.status}`}>
      <div className="section-heading">
        <h3>{g.name}</h3>
        <span className="tag">{labels[g.status]}</span>
      </div>
      <p className="group-detail">
        {g.detail}
        {g.suspendedUntil && <> · until {duration(g.suspendedUntil)}</>}
      </p>
      <ScheduleStrip group={g} />
      <div className="card-bottom">
        <span>
          {g.domains.length} websites ·{" "}
          {g.applicationSummary ?? `${g.applications.length} apps`}
        </span>
        <div className="actions">
          {onAccess && <button onClick={onAccess}>Temporary access</button>}
          {onResume && <button onClick={onResume}>Resume blocking</button>}
          <button aria-label={`Edit ${g.name}`} onClick={onEdit}>
            Open group
          </button>
        </div>
      </div>
    </article>
  );
}
export function Modal({
  title,
  children,
  onClose,
  busy = false,
  wide = false,
}: {
  title: string;
  children: React.ReactNode;
  onClose(): void;
  busy?: boolean;
  wide?: boolean;
}) {
  const ref = useRef<HTMLDialogElement>(null);
  const titleID = useId();
  useEffect(() => {
    const dialog = ref.current;
    dialog?.showModal();
    return () => dialog?.close();
  }, []);
  return (
    <dialog
      ref={ref}
      className={wide ? "wide" : ""}
      aria-labelledby={titleID}
      onCancel={(e) => {
        e.preventDefault();
        if (!busy) onClose();
      }}
    >
      <header className="dialog-heading">
        <h2 id={titleID}>{title}</h2>
        <button disabled={busy} aria-label="Close dialog" onClick={onClose}>
          Close
        </button>
      </header>
      {children}
    </dialog>
  );
}
export function NumberField({
  label,
  value,
  min,
  max,
  onChange,
}: {
  label: string;
  value: number;
  min: number;
  max: number;
  onChange(value: number): void;
}) {
  return (
    <label className="number-field">
      {label}
      <input
        type="number"
        value={value}
        min={min}
        max={max}
        required
        onChange={(e) => {
          const n = Number(e.target.value);
          if (Number.isInteger(n)) onChange(n);
        }}
      />
    </label>
  );
}
