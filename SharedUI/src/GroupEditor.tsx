import type React from "react";
import { useMemo, useRef, useState } from "react";
import { LockKey, LockOpen } from "@phosphor-icons/react";
import type { Group, Reply, Slot } from "./contract.ts";
import {
  clock,
  days,
  daySegments,
  policyName,
  policyWarning,
} from "./presentation.ts";
import { Modal, NumberField } from "./components.tsx";
import { duration } from "./view-format.ts";
import { temporaryPassageDescription } from "./temporary-passage.ts";

export function newGroup(): Group {
  return {
    id: crypto.randomUUID(),
    name: "",
    enabled: true,
    domains: [],
    applications: [],
    status: "disabled",
    detail: "Not saved",
    canEdit: true,
    schedule: { mode: "block", slots: [] },
    changePolicy: { kind: "passage", words: 40, delayDays: 0 },
    temporaryPolicy: {
      allowed: false,
      words: 40,
      maximumMinutes: 60,
      resetDays: null,
    },
  };
}

const STEP = 30;
const ROWS = 1440 / STEP;
const key = (weekday: number, row: number) => `${weekday}:${row}`;
/** Painted cells for display. A cell is painted when its midpoint is covered. */
function cellsFrom(slots: Slot[]): Set<string> {
  const cells = new Set<string>();
  for (const d of days) {
    for (const [s, e] of daySegments(slots, d.id)) {
      for (let r = 0; r < ROWS; r++) {
        const mid = r * STEP + STEP / 2;
        if (mid >= s && mid < e) cells.add(key(d.id, r));
      }
    }
  }
  return cells;
}
/** Contiguous runs per day, then identical runs share one window across weekdays. */
function slotsFrom(cells: Set<string>): Slot[] {
  const runs = new Map<string, number[]>();
  for (const d of days) {
    let start = -1;
    for (let r = 0; r <= ROWS; r++) {
      const on = r < ROWS && cells.has(key(d.id, r));
      if (on && start < 0) start = r;
      if (!on && start >= 0) {
        const id = `${start * STEP}-${r * STEP}`;
        runs.set(id, [...(runs.get(id) ?? []), d.id]);
        start = -1;
      }
    }
  }
  return [...runs.entries()].map(([id, weekdays]) => {
    const [s, e] = id.split("-").map(Number);
    return {
      id: crypto.randomUUID(),
      weekdays,
      startMinutes: s,
      endMinutes: e,
    };
  });
}
/** Exact (minute-precision) complement, so switching meaning never rounds. */
function invert(slots: Slot[]): Slot[] {
  const out: Slot[] = [];
  for (const d of days) {
    const segs = daySegments(slots, d.id).sort((a, b) => a[0] - b[0]);
    let cursor = 0;
    for (const [s, e] of segs) {
      if (s > cursor)
        out.push({
          id: crypto.randomUUID(),
          weekdays: [d.id],
          startMinutes: cursor,
          endMinutes: s,
        });
      cursor = Math.max(cursor, e);
    }
    if (cursor < 1440)
      out.push({
        id: crypto.randomUUID(),
        weekdays: [d.id],
        startMinutes: cursor,
        endMinutes: 1440,
      });
  }
  return out;
}
function weeklyMinutes(slots: Slot[]): number {
  return days.reduce(
    (sum, d) =>
      sum + daySegments(slots, d.id).reduce((n, [s, e]) => n + e - s, 0),
    0,
  );
}
const hour = (m: number) => {
  const h = Math.floor(m / 60) % 24;
  return `${h % 12 === 0 ? 12 : h % 12} ${h < 12 ? "AM" : "PM"}`;
};

function SchedulePainter({
  slots,
  mode,
  onChange,
  onMode,
}: {
  slots: Slot[];
  mode: "block" | "allow";
  onChange(slots: Slot[]): void;
  onMode(mode: "block" | "allow"): void;
}) {
  const cells = useMemo(() => cellsFrom(slots), [slots]);
  const paint = useRef<{ value: boolean; cells: Set<string> } | null>(null);
  const exact = slots.some(
    (s) => s.startMinutes % STEP !== 0 || s.endMinutes % STEP !== 0,
  );
  const meaning = mode === "allow" ? "Allowed" : "Blocked";
  const other = mode === "allow" ? "Blocked" : "Allowed";
  const apply = (id: string | undefined) => {
    const p = paint.current;
    if (!p || !id) return;
    if (p.value) p.cells.add(id);
    else p.cells.delete(id);
    onChange(slotsFrom(p.cells));
  };
  const cellAt = (x: number, y: number) =>
    (document.elementFromPoint(x, y) as HTMLElement | null)?.dataset?.cell;
  return (
    <div className="painter">
      <div className="painter-head">
        <div className="segmented" role="group" aria-label="Painted cells mean">
          <button
            type="button"
            aria-pressed={mode === "allow"}
            onClick={() => onMode("allow")}
          >
            Allowed
          </button>
          <button
            type="button"
            aria-pressed={mode === "block"}
            onClick={() => onMode("block")}
          >
            Disallowed
          </button>
        </div>
        <span className="key">
          <i className="on" /> {meaning}
        </span>
        <span className="key">
          <i /> {other}
        </span>
      </div>
      <div
        className="painter-grid"
        role="grid"
        aria-label={`Weekly schedule. Painted cells are ${meaning.toLowerCase()}.`}
        onContextMenu={(e) => e.preventDefault()}
        onPointerDown={(e) => {
          const id = (e.target as HTMLElement).dataset.cell;
          if (!id) return;
          e.preventDefault();
          paint.current = {
            value: e.button === 2 ? false : !cells.has(id),
            cells: new Set(cells),
          };
          apply(id);
        }}
        onPointerMove={(e) => {
          if (paint.current) apply(cellAt(e.clientX, e.clientY));
        }}
        onPointerUp={() => (paint.current = null)}
        onPointerCancel={() => (paint.current = null)}
        onPointerLeave={() => (paint.current = null)}
      >
        <span className="corner" />
        {days.map((d) => (
          <span key={d.id} className="day-head" role="columnheader">
            {d.name}
          </span>
        ))}
        {Array.from({ length: ROWS }, (_, r) => (
          <Row key={r} r={r} cells={cells} />
        ))}
      </div>
      <p className="painter-help">
        Drag to paint {meaning.toLowerCase()} time · drag from a painted cell,
        or right-drag, to erase · 30-minute steps
      </p>
      {exact && (
        <p className="painter-help warn">
          Some windows use exact minutes. Painting rounds them to 30-minute
          steps; use Exact times below to keep them.
        </p>
      )}
      <div className="actions">
        <button
          type="button"
          onClick={() => {
            const next = new Set(cells);
            for (const d of days)
              for (let r = 36; r < 44; r++) next.add(key(d.id, r));
            onChange(slotsFrom(next));
          }}
        >
          Paint evenings
        </button>
        <button type="button" className="danger" onClick={() => onChange([])}>
          Clear all
        </button>
      </div>
    </div>
  );
}
function Row({ r, cells }: { r: number; cells: Set<string> }) {
  return (
    <>
      <span className="time-label">{r % 4 === 0 ? hour(r * STEP) : ""}</span>
      {days.map((d) => {
        const id = key(d.id, r);
        return (
          <span
            key={id}
            data-cell={id}
            className={`cell${cells.has(id) ? " on" : ""}${r % 2 === 0 ? " hour" : ""}`}
            role="gridcell"
            aria-selected={cells.has(id)}
            aria-label={`${d.name} ${clock(r * STEP)}`}
          />
        );
      })}
    </>
  );
}

function LockCard({
  group,
  busy,
  canSave,
  onUnlock,
}: {
  group: Group;
  busy: boolean;
  canSave: boolean;
  onUnlock(): void;
}) {
  const kind = group.changePolicy.kind;
  const phase = group.unlock?.phase ?? (group.canEdit ? "unlocked" : "idle");
  const unlocked = kind === "none" || phase === "unlocked" || group.canEdit;
  const at = group.unlock?.at;
  const title =
    kind === "none"
      ? "Not locked"
      : unlocked
        ? at
          ? `Unlocked until ${duration(at)}`
          : "Unlocked"
        : phase === "waiting"
          ? `Unlocking · opens ${at ? new Date(at).toLocaleString([], { month: "short", day: "numeric", hour: "numeric", minute: "2-digit" }) : "later"}`
          : phase === "confirmationDue"
            ? "Unlock needs today's confirmation"
            : phase === "cancelled"
              ? "Unlock request lapsed"
              : "Locked";
  const detail =
    kind === "none"
      ? "Any change saves immediately."
      : unlocked
        ? "You can loosen this group now. The lock returns when the window closes."
        : `Stricter changes (more sites, longer hours, a stronger lock) save right away. Loosening it needs: ${policyName(kind).toLowerCase()}.`;
  const Icon = unlocked ? LockOpen : LockKey;
  return (
    <div className="lock-card">
      <Icon size={20} weight="bold" aria-hidden="true" />
      <div>
        <strong>{title}</strong>
        <p>{detail}</p>
      </div>
      {!unlocked && (
        <button type="button" disabled={busy || !canSave} onClick={onUnlock}>
          {phase === "idle" || phase === "cancelled"
            ? "Start unlock…"
            : "Continue unlock…"}
        </button>
      )}
    </div>
  );
}

function Section({
  title,
  subtitle,
  children,
}: {
  title: string;
  subtitle: string;
  children: React.ReactNode;
}) {
  return (
    <section className="editor-section">
      <header>
        <h3>{title}</h3>
        <p>{subtitle}</p>
      </header>
      {children}
    </section>
  );
}

export function GroupEditor({
  group,
  live,
  isNew,
  canSave,
  canPick,
  busy,
  error,
  onClose,
  onSave,
  onPick,
  onUnlock,
  onDelete,
  onAccess,
  onResume,
  websiteSupport,
}: {
  group: Group;
  /** Latest host state for this group (status, pause, unlock), separate from the draft. */
  live?: Group;
  isNew: boolean;
  canSave: boolean;
  canPick: boolean;
  busy: boolean;
  error: string;
  onClose(): void;
  onSave(group: Group): Promise<void>;
  onPick(): Promise<Reply | null>;
  onUnlock(): void;
  onDelete?: () => Promise<void>;
  onAccess?: () => void;
  onResume?: () => void;
  websiteSupport: boolean;
}) {
  const [draft, setDraft] = useState(group);
  const current = live ?? group;
  const [domains, setDomains] = useState(group.domains.join("\n"));
  const [confirmDelete, setConfirmDelete] = useState(false);
  const patch = (value: Partial<Group>) =>
    setDraft((d) => ({ ...d, ...value }));
  const setSlots = (slots: Slot[]) =>
    patch({ schedule: { ...draft.schedule, slots } });
  const warning = policyWarning(draft);
  const slotPatch = (id: string, value: Partial<Slot>) =>
    setSlots(
      draft.schedule.slots.map((s) => (s.id === id ? { ...s, ...value } : s)),
    );
  const minutes = weeklyMinutes(draft.schedule.slots);
  const windows = draft.schedule.slots.length;
  return (
    <Modal
      title={isNew ? "New blocking group" : "Edit blocking group"}
      onClose={onClose}
      busy={busy}
      wide
    >
      <form
        className="editor"
        onSubmit={(e) => {
          e.preventDefault();
          void onSave({
            ...draft,
            name: draft.name.trim(),
            domains: [...new Set(domains.split(/[\s,]+/).filter(Boolean))],
          });
        }}
      >
        <div className="dialog-content">
          <p className="editor-intro">
            Choose what to block, when to allow access, and how changes are
            protected.
          </p>
          {error && (
            <div className="banner error" role="alert">
              {error}
            </div>
          )}
          {!canSave && (
            <div className="banner">
              Read-only: this host has not connected group editing.
            </div>
          )}
          {!isNew && (
            <LockCard
              group={{ ...current, canEdit: current.canEdit || group.canEdit }}
              busy={busy}
              canSave={canSave}
              onUnlock={onUnlock}
            />
          )}

          <fieldset disabled={!canSave || busy}>
            <Section
              title="Identity & behavior"
              subtitle="Name this group and choose whether it is on."
            >
              <label>
                Name
                <input
                  required
                  maxLength={120}
                  value={draft.name}
                  placeholder="Blocking group name"
                  onChange={(e) => patch({ name: e.target.value })}
                />
              </label>
              <label className="check">
                <input
                  type="checkbox"
                  checked={draft.enabled}
                  onChange={(e) => patch({ enabled: e.target.checked })}
                />
                Enabled
              </label>
            </Section>
          </fieldset>

          <fieldset disabled={!canSave || busy}>
            <Section
              title="Websites & applications"
              subtitle="What this group blocks on this device."
            >
              <label>
                Website domains
                <textarea
                  disabled={!websiteSupport}
                  rows={4}
                  value={domains}
                  onChange={(e) => setDomains(e.target.value)}
                  placeholder="example.com"
                  spellCheck={false}
                  autoCapitalize="none"
                />
                <small>
                  {websiteSupport
                    ? "One domain per line. Your device validates supported targets before saving."
                    : "Website filtering is not available in this backend yet. Application blocking is available below."}
                </small>
              </label>
              <div className="list-row">
                <span>
                  {draft.applicationSummary ??
                    `${draft.applications.length} selected applications`}
                </span>
                <button
                  type="button"
                  disabled={!canPick}
                  onClick={async () => {
                    const reply = await onPick();
                    if (reply?.applications)
                      patch({
                        applications: reply.applications,
                        applicationSummary: reply.applicationSummary,
                        selectionToken: reply.selectionToken,
                      });
                  }}
                >
                  Choose applications
                </button>
              </div>
              {draft.applications.map((a) => (
                <div className="list-row" key={a}>
                  <p className="path">{a}</p>
                  <button
                    type="button"
                    aria-label={`Remove ${a}`}
                    onClick={() =>
                      patch({
                        applications: draft.applications.filter((v) => v !== a),
                      })
                    }
                  >
                    Remove
                  </button>
                </div>
              ))}
            </Section>
          </fieldset>

          <fieldset disabled={!canSave || busy}>
            <Section
              title="Schedule"
              subtitle={`${draft.schedule.mode === "allow" ? "Allowance" : "Blocking"} windows · ${windows} ${windows === 1 ? "window" : "windows"} · ${Math.round((minutes / 60) * 10) / 10} hours / week`}
            >
              <SchedulePainter
                slots={draft.schedule.slots}
                mode={draft.schedule.mode}
                onChange={setSlots}
                onMode={(mode) =>
                  mode !== draft.schedule.mode &&
                  patch({
                    schedule: { mode, slots: invert(draft.schedule.slots) },
                  })
                }
              />
              <details className="exact-times">
                <summary>
                  Exact times · {windows} {windows === 1 ? "window" : "windows"}
                </summary>
                <p>
                  All times use this device’s local timezone. Overnight windows
                  carry into the following day. Lockdowns override allowance
                  windows.
                </p>
                {draft.schedule.slots.map((s) => (
                  <div className="window-editor" key={s.id}>
                    <div className="weekdays">
                      {days.map((d) => (
                        <label key={d.id}>
                          <input
                            type="checkbox"
                            checked={s.weekdays.includes(d.id)}
                            onChange={(e) =>
                              slotPatch(s.id, {
                                weekdays: e.target.checked
                                  ? [...s.weekdays, d.id]
                                  : s.weekdays.filter((v) => v !== d.id),
                              })
                            }
                          />
                          {d.name}
                        </label>
                      ))}
                    </div>
                    <div className="time-row">
                      <label>
                        From
                        <input
                          type="time"
                          value={clock(s.startMinutes)}
                          onChange={(e) => {
                            const [h, m] = e.target.value
                              .split(":")
                              .map(Number);
                            if (Number.isFinite(h + m))
                              slotPatch(s.id, { startMinutes: h * 60 + m });
                          }}
                          required
                        />
                      </label>
                      <label>
                        Until
                        <input
                          type="time"
                          value={
                            s.endMinutes === 1440
                              ? "00:00"
                              : clock(s.endMinutes)
                          }
                          onChange={(e) => {
                            const [h, m] = e.target.value
                              .split(":")
                              .map(Number);
                            if (Number.isFinite(h + m))
                              slotPatch(s.id, { endMinutes: h * 60 + m });
                          }}
                          required
                        />
                      </label>
                      <button
                        type="button"
                        aria-label={`Remove window ${clock(s.startMinutes)} to ${clock(s.endMinutes)}`}
                        onClick={() =>
                          setSlots(
                            draft.schedule.slots.filter((v) => v.id !== s.id),
                          )
                        }
                      >
                        Remove
                      </button>
                    </div>
                  </div>
                ))}
                <button
                  type="button"
                  onClick={() =>
                    setSlots([
                      ...draft.schedule.slots,
                      {
                        id: crypto.randomUUID(),
                        weekdays: [2, 3, 4, 5, 6],
                        startMinutes: 9 * 60,
                        endMinutes: 17 * 60,
                      },
                    ])
                  }
                >
                  Add window
                </button>
              </details>
            </Section>
          </fieldset>

          {!isNew && current.enabled && (onAccess || onResume) && (
            <Section
              title="Temporary access"
              subtitle="Pause this group for a set time. Blocking resumes automatically, even if Holdfast is closed."
            >
              {current.suspendedUntil && (
                <div className="list-row">
                  <span>
                    <strong>
                      Paused until {duration(current.suspendedUntil)}
                    </strong>
                  </span>
                  {onResume && (
                    <button type="button" disabled={busy} onClick={onResume}>
                      Resume now
                    </button>
                  )}
                </div>
              )}
              {current.lockdownUntil ? (
                <p>
                  A lockdown holds this group until{" "}
                  {duration(current.lockdownUntil)}. It overrides temporary
                  access.
                </p>
              ) : !current.temporaryPolicy.allowed ? (
                <p>
                  Temporary access is off for this group. Allowing it is a
                  loosening change and follows the change protection below.
                </p>
              ) : (
                onAccess && (
                  <div>
                    <button
                      type="button"
                      className="danger"
                      disabled={busy}
                      onClick={onAccess}
                    >
                      {current.suspendedUntil
                        ? "Extend pause…"
                        : "Disable temporarily…"}
                    </button>
                    <small>
                      {temporaryPassageDescription(current)} Up to{" "}
                      {current.temporaryPolicy.maximumMinutes / 60} hour(s).
                    </small>
                  </div>
                )
              )}
            </Section>
          )}

          <fieldset disabled={!canSave || busy}>
            <Section
              title="Change protection"
              subtitle="Protects permanent edits, disabling, and deletion. Equivalent or stronger restrictions save without unlocking."
            >
              <label>
                Change policy
                <select
                  value={draft.changePolicy.kind}
                  onChange={(e) =>
                    patch({
                      changePolicy: {
                        ...draft.changePolicy,
                        kind: e.target.value as Group["changePolicy"]["kind"],
                      },
                    })
                  }
                >
                  {group.changePolicy.kind === "inherited" && (
                    <option value="inherited">
                      Use existing app-default policy
                    </option>
                  )}
                  <option value="none">No confirmation</option>
                  <option value="passage">Type a passage</option>
                  <option value="delay">Type a passage, then wait</option>
                  <option value="checkpoints">Repeated confirmations</option>
                </select>
              </label>
              {["delay", "checkpoints"].includes(draft.changePolicy.kind) && (
                <NumberField
                  label="Unlock wait (days)"
                  value={draft.changePolicy.delayDays}
                  min={1}
                  max={365}
                  onChange={(delayDays) =>
                    patch({
                      changePolicy: { ...draft.changePolicy, delayDays },
                    })
                  }
                />
              )}
              {draft.changePolicy.kind !== "none" && (
                <NumberField
                  label="Confirmation passage (words)"
                  value={draft.changePolicy.words}
                  min={20}
                  max={300}
                  onChange={(words) =>
                    patch({ changePolicy: { ...draft.changePolicy, words } })
                  }
                />
              )}
            </Section>
          </fieldset>

          <fieldset disabled={!canSave || busy}>
            <Section
              title="Temporary access policy"
              subtitle="Controls timed exceptions only. It does not unlock editing; blocking resumes automatically."
            >
              <label className="check">
                <input
                  type="checkbox"
                  checked={draft.temporaryPolicy.allowed}
                  onChange={(e) =>
                    patch({
                      temporaryPolicy: {
                        ...draft.temporaryPolicy,
                        allowed: e.target.checked,
                      },
                    })
                  }
                />
                Allow temporary access with a passage
              </label>
              {draft.temporaryPolicy.allowed && (
                <>
                  <NumberField
                    label="Base access passage (words)"
                    value={draft.temporaryPolicy.words}
                    min={20}
                    max={300}
                    onChange={(words) =>
                      patch({
                        temporaryPolicy: { ...draft.temporaryPolicy, words },
                      })
                    }
                  />
                  <NumberField
                    label="Maximum temporary access (hours)"
                    value={draft.temporaryPolicy.maximumMinutes / 60}
                    min={1}
                    max={8}
                    onChange={(h) =>
                      patch({
                        temporaryPolicy: {
                          ...draft.temporaryPolicy,
                          maximumMinutes: h * 60,
                        },
                      })
                    }
                  />
                  <label className="check">
                    <input
                      type="checkbox"
                      checked={draft.temporaryPolicy.resetDays !== null}
                      onChange={(e) =>
                        patch({
                          temporaryPolicy: {
                            ...draft.temporaryPolicy,
                            resetDays: e.target.checked ? 7 : null,
                          },
                        })
                      }
                    />
                    Increase passage length with each use
                  </label>
                  {draft.temporaryPolicy.resetDays !== null && (
                    <>
                      <NumberField
                        label="Reset backoff after (days)"
                        value={draft.temporaryPolicy.resetDays}
                        min={1}
                        max={365}
                        onChange={(resetDays) =>
                          patch({
                            temporaryPolicy: {
                              ...draft.temporaryPolicy,
                              resetDays,
                            },
                          })
                        }
                      />
                      <small>
                        1×, 2×, 3×, 4×… from the first successful use. Your
                        device computes the final requirement.
                      </small>
                    </>
                  )}
                </>
              )}
              {warning && <div className="banner warning">{warning}</div>}
            </Section>
          </fieldset>
        </div>
        <div className="dialog-actions">
          <span className="action-note">
            Baseline blocking group · independent targets
          </span>
          {onDelete &&
            (confirmDelete ? (
              <button
                type="button"
                className="danger"
                disabled={busy || !canSave}
                onClick={() => void onDelete()}
              >
                Confirm delete
              </button>
            ) : (
              <button
                type="button"
                disabled={busy || !canSave}
                onClick={() => setConfirmDelete(true)}
              >
                Delete group
              </button>
            ))}
          <button type="button" disabled={busy} onClick={onClose}>
            Cancel
          </button>
          <button
            className="primary"
            disabled={
              !canSave ||
              busy ||
              !draft.name.trim() ||
              draft.schedule.slots.some((s) => s.weekdays.length === 0)
            }
            type="submit"
          >
            {busy ? "Saving…" : "Save group"}
          </button>
        </div>
      </form>
    </Modal>
  );
}
