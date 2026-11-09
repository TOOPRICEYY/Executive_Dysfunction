import { useEffect, useRef, useState } from "react";
import {
  ArrowsClockwise,
  ArrowUpRight,
  CaretDown,
  CaretRight,
  Clock,
  House,
  Key,
  LockKey,
  LockOpen,
  Plus,
  ShieldCheck,
} from "@phosphor-icons/react";
import type { Group, Preset, RetreatGroup, Snapshot } from "./contract.ts";
import {
  byNow,
  bypassCounts,
  clock,
  daySegments,
  groupNow,
  isBlockingState,
  laneLabel,
  lanesFor,
  lockChip,
  nextLine,
  nowHeadline,
  presetLock,
  sameDay,
  targetSummary,
} from "./presentation.ts";
import { duration } from "./view-format.ts";

/** Phone layout switch. Structure differs (as the native iOS and Mac apps did), not just spacing. */
export function useCompact(query = "(max-width: 700px)"): boolean {
  const get = () =>
    typeof matchMedia === "function" && matchMedia(query).matches;
  const [compact, setCompact] = useState(get);
  useEffect(() => {
    if (typeof matchMedia !== "function") return;
    const list = matchMedia(query);
    const change = () => setCompact(list.matches);
    list.addEventListener("change", change);
    return () => list.removeEventListener("change", change);
  }, [query]);
  return compact;
}
/** Re-render on a timer so "blocking now · until 14:00" and the now line stay true. */
export function useNow(ms = 30_000): Date {
  const [now, setNow] = useState(() => new Date());
  useEffect(() => {
    const t = setInterval(() => setNow(new Date()), ms);
    return () => clearInterval(t);
  }, [ms]);
  return now;
}
function remembered(
  key: string,
  fallback: boolean,
): [boolean, (v: boolean) => void] {
  const [value, setValue] = useState(() => {
    try {
      const v = localStorage.getItem(key);
      return v === null ? fallback : v === "1";
    } catch {
      return fallback;
    }
  });
  return [
    value,
    (v) => {
      setValue(v);
      try {
        localStorage.setItem(key, v ? "1" : "0");
      } catch {
        /* Per-viewer convenience only. */
      }
    },
  ];
}

const lockIcons = {
  open: LockOpen,
  key: Key,
  clock: Clock,
  repeat: ArrowsClockwise,
  lock: LockKey,
};
function LockChip({
  kind,
  delayDays,
}: {
  kind: Group["changePolicy"]["kind"];
  delayDays: number;
}) {
  const chip = lockChip(kind, delayDays);
  const Icon = lockIcons[chip.icon];
  return (
    <span className="chip" title={`Change protection: ${chip.label}`}>
      <Icon size={12} weight="bold" aria-hidden="true" />
      {chip.label}
    </span>
  );
}

export function GroupRow({
  group: g,
  onEdit,
}: {
  group: Group;
  onEdit(): void;
}) {
  const now = groupNow(g);
  // Styled as blocking only when the host also confirms enforcement.
  const enforced = isBlockingState(now.state) && g.status !== "unsupported";
  return (
    <button
      className={`object-row now-${now.state}${enforced ? " is-blocking" : ""}`}
      onClick={onEdit}
      aria-label={`Edit ${g.name}`}
    >
      <span className="state-bar" aria-hidden="true" />
      <span className="row-copy">
        <strong role="heading" aria-level={3}>
          {g.name}
        </strong>
        <span className="row-headline">{now.headline}</span>
        {g.status === "unsupported" && (
          <span className="row-warning">{g.detail}</span>
        )}
        {g.lockdownUntil && now.state === "lockdown" ? (
          <span className="row-badge">
            <ShieldCheck size={13} aria-hidden="true" /> Lockdown · until{" "}
            {duration(g.lockdownUntil)} · overrides schedule and temporary
            access
          </span>
        ) : (
          g.suspendedUntil && (
            <span className="row-badge allowance">
              Temporarily allowed until {duration(g.suspendedUntil)}
            </span>
          )
        )}
        <small>{targetSummary(g)}</small>
      </span>
      <LockChip
        kind={g.changePolicy.kind}
        delayDays={g.changePolicy.delayDays}
      />
      <CaretRight
        className="row-chevron"
        size={14}
        weight="bold"
        aria-hidden="true"
      />
    </button>
  );
}
function RetreatGroupRow({
  group: g,
  onOpen,
}: {
  group: RetreatGroup;
  onOpen(): void;
}) {
  return (
    <button
      className={`object-row now-${g.now.state}${isBlockingState(g.now.state) ? " is-blocking" : ""}`}
      onClick={onOpen}
      aria-label={`Open retreat for ${g.name}`}
    >
      <span className="state-bar" aria-hidden="true" />
      <span className="row-copy">
        <span className="row-title">
          <strong role="heading" aria-level={3}>
            {g.name}
          </strong>
          <span className="chip">Retreat</span>
        </span>
        <span className="row-headline">{g.now.headline}</span>
        <small>{g.targets}</small>
      </span>
      <LockChip kind={g.lock} delayDays={g.delayDays} />
      <CaretRight
        className="row-chevron"
        size={14}
        weight="bold"
        aria-hidden="true"
      />
    </button>
  );
}

export function PresetGrid({
  presets,
  disabled,
  onPick,
  onCustom,
}: {
  presets: Preset[];
  disabled: boolean;
  onPick(p: Preset): void;
  onCustom?: () => void;
}) {
  return (
    <div className="preset-start">
      <h3>Start with a preset</h3>
      <p>Each adds an editable group with sites, a schedule and a lock.</p>
      <div className="preset-grid">
        {presets.map((p) => (
          <button
            key={p.id}
            disabled={disabled}
            onClick={() => onPick(p)}
            data-preset={p.id}
          >
            <strong>{p.name}</strong>
            <span>{p.summary}</span>
            <em>{presetLock(p.lock)}</em>
          </button>
        ))}
      </div>
      {onCustom && (
        <button className="link" disabled={disabled} onClick={onCustom}>
          Or build your own
        </button>
      )}
    </div>
  );
}
function PresetMenu({
  presets,
  disabled,
  onPick,
}: {
  presets: Preset[];
  disabled: boolean;
  onPick(p: Preset): void;
}) {
  const ref = useRef<HTMLDetailsElement>(null);
  return (
    <details className="menu" ref={ref}>
      <summary
        className={`link${disabled ? " is-disabled" : ""}`}
        title="Adds a ready-made Blocking Group. Everything stays editable."
      >
        Start from preset{" "}
        <CaretDown size={12} weight="bold" aria-hidden="true" />
      </summary>
      <div className="menu-list" role="menu">
        {presets.map((p) => (
          <button
            key={p.id}
            role="menuitem"
            disabled={disabled}
            onClick={() => {
              ref.current?.removeAttribute("open");
              onPick(p);
            }}
          >
            <strong>{p.name}</strong>
            <span>{p.summary}</span>
          </button>
        ))}
      </div>
    </details>
  );
}

/** One lane per group across 24 hours, one day at a time, with a 7-day strip. */
export function ScheduleLanes({
  snapshot,
  onSelect,
}: {
  snapshot: Snapshot;
  onSelect(id: string): void;
}) {
  const [offset, setOffset] = useState(0);
  const now = useNow(60_000);
  const today = new Date(now.getFullYear(), now.getMonth(), now.getDate());
  const sources = lanesFor(snapshot);
  const hostDay = snapshot.schedule?.days.find((d) =>
    sameDay(
      new Date(d.start),
      new Date(today.getFullYear(), today.getMonth(), today.getDate() + offset),
    ),
  );
  const dayStart = hostDay
    ? Date.parse(hostDay.start)
    : new Date(
        today.getFullYear(),
        today.getMonth(),
        today.getDate() + offset,
      ).getTime();
  const dayEnd = hostDay
    ? Date.parse(hostDay.end)
    : new Date(
        today.getFullYear(),
        today.getMonth(),
        today.getDate() + offset + 1,
      ).getTime();
  const span = dayEnd - dayStart;
  const frac = (t: number) => Math.min(1, Math.max(0, (t - dayStart) / span));
  const weekday = new Date(dayStart).getDay() + 1;
  const isToday = offset === 0;
  const lanes = sources.map((src) => {
    let segments: [number, number][];
    if (hostDay) {
      segments = (
        hostDay.lanes.find((l) => l.id === src.id)?.intervals ?? []
      ).map((i) => [frac(Date.parse(i.start)), frac(Date.parse(i.end))]);
    } else {
      // Older hosts: draw saved windows only (never a claim about enforcement).
      const g = snapshot.groups.find((v) => v.id === src.id);
      segments =
        g && g.enabled
          ? fallbackSegments(g, weekday).map(([s, e]) => [s / 1440, e / 1440])
          : [];
    }
    const minutes = Math.round(
      segments.reduce((sum, [s, e]) => sum + (e - s), 0) * (span / 60_000),
    );
    return { ...src, segments, minutes };
  });
  const ordered = isToday
    ? byNow(lanes, (l) => l.now ?? { state: "idle", headline: "" })
    : [...lanes].sort(
        (a, b) =>
          (a.segments[0]?.[0] ?? 2) - (b.segments[0]?.[0] ?? 2) ||
          a.name.localeCompare(b.name),
      );
  const selected = new Date(dayStart);
  return (
    <section className="panel schedule-panel" aria-label="Schedule">
      <div className="schedule-head">
        <h2>Schedule</h2>
        {isToday ? (
          <span className="schedule-now">
            Now{" "}
            {now.toLocaleTimeString([], { hour: "numeric", minute: "2-digit" })}
          </span>
        ) : (
          <span className="schedule-date">
            {selected.toLocaleDateString([], {
              weekday: "long",
              month: "short",
              day: "numeric",
            })}
          </span>
        )}
      </div>
      <div className="schedule-days" role="group" aria-label="Schedule day">
        {Array.from({ length: 7 }, (_, i) => {
          const date = new Date(
            today.getFullYear(),
            today.getMonth(),
            today.getDate() + i,
          );
          return (
            <button
              key={i}
              aria-pressed={offset === i}
              aria-label={
                i === 0
                  ? "Today"
                  : date.toLocaleDateString([], {
                      weekday: "long",
                      month: "long",
                      day: "numeric",
                    })
              }
              onClick={() => setOffset(i)}
            >
              <strong>
                {i === 0
                  ? "Today"
                  : date.toLocaleDateString([], { weekday: "short" })}
              </strong>
              <span>{date.getDate()}</span>
            </button>
          );
        })}
      </div>
      {!ordered.length ? (
        <p className="schedule-empty">
          Enable a Blocking Group to see its schedule here.
        </p>
      ) : (
        <div className="lanes">
          <div className="lane-axis" aria-hidden="true">
            <span />
            <div>
              {[0, 6, 12, 18].map((h) => (
                <span key={h} style={{ left: `${(h / 24) * 100}%` }}>
                  {String(h).padStart(2, "0")}
                </span>
              ))}
            </div>
          </div>
          {ordered.map((lane) => {
            const label = laneLabel(lane.now, lane.minutes, isToday, now);
            const active =
              isToday && lane.now && isBlockingState(lane.now.state);
            return (
              <button
                key={lane.id}
                className="schedule-lane"
                onClick={() => onSelect(lane.id)}
                aria-label={`${lane.name}. ${isToday && lane.now ? lane.now.headline : label}`}
              >
                <span className="lane-name">
                  <strong>{lane.name}</strong>
                  <small className={active ? "is-active" : ""}>{label}</small>
                </span>
                <span className="lane-track">
                  {lane.segments.map(([s, e], i) => (
                    <span
                      key={i}
                      className="lane-window"
                      style={{
                        left: `${s * 100}%`,
                        width: `max(2px, ${(e - s) * 100}%)`,
                      }}
                      title={`${clock(Math.round(s * 1440))}–${clock(Math.round(e * 1440))}`}
                    />
                  ))}
                  {isToday && (
                    <span
                      className="lane-now"
                      style={{ left: `${frac(now.getTime()) * 100}%` }}
                    />
                  )}
                </span>
              </button>
            );
          })}
        </div>
      )}
    </section>
  );
}
function fallbackSegments(g: Group, weekday: number): [number, number][] {
  const saved = daySegments(g.schedule.slots, weekday).sort(
    (a, b) => a[0] - b[0],
  );
  if (g.schedule.mode === "block") return saved;
  const out: [number, number][] = [];
  let cursor = 0;
  for (const [s, e] of saved) {
    if (s > cursor) out.push([cursor, s]);
    cursor = Math.max(cursor, e);
  }
  if (cursor < 1440) out.push([cursor, 1440]);
  return out;
}

function StatusBanner({
  snapshot,
  busy,
  compact,
  onEnforcement,
  onAdvanced,
  onDiagnostics,
  open,
  setOpen,
}: {
  snapshot: Snapshot;
  busy: boolean;
  compact: boolean;
  onEnforcement?: () => void;
  onAdvanced?: () => void;
  onDiagnostics?: () => void;
  open: boolean;
  setOpen(v: boolean): void;
}) {
  const e = snapshot.enforcement;
  const groupsOn =
    snapshot.groups.filter((g) => g.enabled).length +
    (snapshot.retreatGroups?.length ?? 0);
  const running = snapshot.retreats.filter((r) => r.state === "active").length;
  const controlsLabel =
    snapshot.platform === "ios"
      ? "Screen Time"
      : snapshot.platform === "windows"
        ? "Device controls"
        : "Filter controls";
  return (
    <section
      className={`status-banner tone-${e.state}${compact ? " compact" : ""}`}
      aria-label="Device enforcement"
    >
      <div className="status-main">
        <h2>{e.headline ?? e.title}</h2>
        <div className="status-badges">
          {snapshot.sync.detail &&
            snapshot.sync.state !== "current" &&
            !compact && (
              <span className="badge truncate" title={snapshot.sync.detail}>
                {snapshot.sync.detail}
              </span>
            )}
          <span className="badge">{groupsOn} groups on</span>
          {running > 0 && (
            <span className="badge">
              {running} {running === 1 ? "retreat" : "retreats"} running
            </span>
          )}
          <button
            className="banner-button"
            aria-expanded={open}
            onClick={() => setOpen(!open)}
          >
            {controlsLabel}
          </button>
        </div>
      </div>
      {open && (
        <div className="status-controls">
          <p>{e.detail}</p>
          {e.title !== (e.headline ?? e.title) && <p>{e.title}</p>}
          <div className="actions">
            {onEnforcement && (
              <button disabled={busy} onClick={onEnforcement}>
                {snapshot.enforcementEnabled
                  ? snapshot.platform === "macos"
                    ? "Turn web filter off…"
                    : "Disable with passage…"
                  : snapshot.platform === "macos"
                    ? "Install / turn on web filter"
                    : snapshot.platform === "ios"
                      ? "Allow Screen Time access"
                      : "Enable blocking"}
              </button>
            )}
            {onAdvanced && (
              <button disabled={busy} onClick={onAdvanced}>
                Advanced controls
              </button>
            )}
            {onDiagnostics && (
              <button disabled={busy} onClick={onDiagnostics}>
                Diagnostics
              </button>
            )}
          </div>
        </div>
      )}
    </section>
  );
}

function BypassPanel({
  snapshot,
  compact,
  onHistory,
}: {
  snapshot: Snapshot;
  compact: boolean;
  onHistory(id: string): void;
}) {
  const [open, setOpen] = remembered("holdfast.ui.bypasses-expanded", !compact);
  const [period, setPeriod] = useState(7);
  const counts = bypassCounts(
    snapshot.bypasses,
    Date.now() - period * 86_400_000,
  );
  const total = counts.reduce((n, c) => n + c.count, 0);
  const coverage =
    snapshot.platform === "ios"
      ? "This iPhone or iPad only. App grants include requests opened from a Screen Time shield."
      : "Successful temporary-access grants · this device";
  return (
    <section className="panel bypass-panel collapsible" aria-label="Bypasses">
      <button
        className="collapse-head"
        aria-expanded={open}
        onClick={() => setOpen(!open)}
      >
        <span>
          <strong>Bypasses</strong>
          <small>
            Temporary access you granted · {total} in {period} days
          </small>
        </span>
        <CaretDown
          size={14}
          weight="bold"
          className="collapse-caret"
          aria-hidden="true"
        />
      </button>
      {open && (
        <div className="collapse-body">
          <div className="bypass-toolbar">
            <p>{coverage}</p>
            <label className="period-control">
              <span className="sr-only">Bypass period</span>
              <select
                value={period}
                onChange={(e) => setPeriod(Number(e.target.value))}
              >
                <option value={7}>Last 7 days</option>
                <option value={30}>Last 30 days</option>
                <option value={90}>Last 90 days</option>
              </select>
            </label>
          </div>
          {snapshot.groups.length > 0 && (
            <div className="bypass-list">
              {snapshot.groups.map((g) => {
                const n = counts.find((c) => c.groupID === g.id)?.count ?? 0;
                return (
                  <button
                    key={g.id}
                    className="bypass-row"
                    onClick={() => onHistory(g.id)}
                  >
                    <span>{g.name}</span>
                    <strong>{n}</strong>
                  </button>
                );
              })}
            </div>
          )}
          {!counts.length && (
            <p className="quiet-note">No recorded bypasses in this period.</p>
          )}
          <button className="link" onClick={() => onHistory("all")}>
            View all bypasses & configure…
          </button>
        </div>
      )}
    </section>
  );
}

export function Dashboard({
  snapshot,
  busy,
  edit,
  onNew,
  onPreset,
  onRetreats,
  onNewRetreat,
  onLockdown,
  onHistory,
  onEnforcement,
  onAdvanced,
  onDiagnostics,
  controlsOpen,
  setControlsOpen,
}: {
  snapshot: Snapshot;
  busy: boolean;
  edit(group: Group): void;
  onNew?: () => void;
  onPreset?: (p: Preset) => void;
  onRetreats(): void;
  onNewRetreat?: () => void;
  onLockdown?: () => void;
  onHistory(id: string): void;
  onEnforcement?: () => void;
  onAdvanced?: () => void;
  onDiagnostics?: () => void;
  controlsOpen: boolean;
  setControlsOpen(v: boolean): void;
}) {
  const compact = useCompact();
  useNow(30_000);
  const [search, setSearch] = useState("");
  const live = snapshot.retreats.filter((r) => r.state === "active");
  const planned = snapshot.retreats.filter(
    (r) => r.state === "scheduled" || r.state === "draft",
  );
  const groups = byNow(snapshot.groups, groupNow);
  const retreatGroups = byNow(snapshot.retreatGroups ?? [], (r) => r.now);
  const total = groups.length + retreatGroups.length;
  const match = (name: string) =>
    !search || name.toLowerCase().includes(search.toLowerCase());
  const presets = onPreset ? (snapshot.presets ?? []) : [];
  const blocking =
    snapshot.enforcement.state === "active" &&
    [
      ...groups.filter((g) => g.status !== "unsupported").map(groupNow),
      ...retreatGroups.map((r) => r.now),
    ].some((n) => isBlockingState(n.state));

  const groupsPanel = (
    <section className="object-panel" aria-label="Blocking Groups">
      <header className="panel-heading">
        <h2>Blocking Groups</h2>
        <span className="count-badge">{total}</span>
      </header>
      {total === 0 ? (
        presets.length ? (
          <PresetGrid
            presets={presets}
            disabled={busy}
            onPick={(p) => onPreset?.(p)}
            onCustom={onNew}
          />
        ) : (
          <p className="panel-empty">
            Create a group to choose apps, websites and allowance windows.
          </p>
        )
      ) : (
        <>
          {total > 4 && (
            <div className="group-search">
              <input
                type="search"
                aria-label="Find a Blocking Group"
                placeholder="Find a Blocking Group"
                value={search}
                onChange={(e) => setSearch(e.target.value)}
              />
            </div>
          )}
          {groups
            .filter((g) => match(g.name))
            .map((g) => (
              <GroupRow key={g.id} group={g} onEdit={() => edit(g)} />
            ))}
          {retreatGroups
            .filter((g) => match(g.name))
            .map((g) => (
              <RetreatGroupRow key={g.id} group={g} onOpen={onRetreats} />
            ))}
          {!!search &&
            ![...groups, ...retreatGroups].some((g) => match(g.name)) && (
              <p className="panel-empty">
                No matching groups. Try a different name.
              </p>
            )}
        </>
      )}
      {compact && total > 0 && onNew && (
        <button className="add-row" disabled={busy} onClick={onNew}>
          <Plus size={14} weight="bold" aria-hidden="true" /> New blocking group
        </button>
      )}
    </section>
  );

  const retreatsPanel =
    compact && !live.length ? (
      <button className="slim-row" onClick={onNewRetreat ?? onRetreats}>
        <House size={16} aria-hidden="true" />
        <span>No retreat running</span>
        <em>Plan one</em>
        <CaretRight size={12} weight="bold" aria-hidden="true" />
      </button>
    ) : (
      <section className="object-panel" aria-label="Active retreats">
        <header className="panel-heading">
          <h2>Active retreats</h2>
          <span className="count-badge">{live.length}</span>
          {!compact && (
            <button disabled={!onNewRetreat || busy} onClick={onNewRetreat}>
              New retreat
            </button>
          )}
        </header>
        {live.map((r) => (
          <button
            className="object-row is-blocking retreat-object"
            key={r.id}
            onClick={onRetreats}
          >
            <span className="state-bar" aria-hidden="true" />
            <span className="row-copy">
              <strong role="heading" aria-level={3}>
                {r.name}
              </strong>
              <small>
                {r.groupNames.length}{" "}
                {r.groupNames.length === 1 ? "group" : "groups"} · ends{" "}
                {new Date(r.endsAt).toLocaleDateString([], {
                  month: "short",
                  day: "numeric",
                })}
              </small>
              <small>{r.groupNames.join(" · ")}</small>
            </span>
            <span className="chip">{r.changePolicyLabel}</span>
            <ArrowUpRight size={14} weight="bold" aria-hidden="true" />
          </button>
        ))}
        {!live.length && (
          <p className="panel-empty">
            Plan a longer break using your Blocking Groups.
          </p>
        )}
      </section>
    );

  return (
    <>
      <header
        className={`now-header${compact ? " hero" : ""}${compact && blocking ? " is-blocking" : ""}`}
      >
        <h1>{nowHeadline(snapshot)}</h1>
        <p className="heading-detail" data-testid="dashboard-next-change">
          {nextLine(snapshot)}
        </p>
        {snapshot.lockdown && compact && (
          <p className="row-badge">
            <ShieldCheck size={13} aria-hidden="true" />{" "}
            {snapshot.lockdown.groupNames.join(", ")} · Lockdown until{" "}
            {duration(snapshot.lockdown.endsAt)}
          </p>
        )}
        {compact && (
          <button
            className="hero-button"
            disabled={!onLockdown || busy}
            onClick={onLockdown}
          >
            <ShieldCheck size={15} aria-hidden="true" />
            {snapshot.lockdown ? "Manage lockdowns" : "Lockdown"}
          </button>
        )}
      </header>
      <StatusBanner
        snapshot={snapshot}
        busy={busy}
        compact={compact}
        onEnforcement={onEnforcement}
        onAdvanced={onAdvanced}
        onDiagnostics={onDiagnostics}
        open={controlsOpen}
        setOpen={setControlsOpen}
      />
      {snapshot.lockdown && !compact && (
        <section
          className="panel lockdown-panel"
          aria-label="Temporary lockdowns"
        >
          <div className="lockdown-head">
            <h2>Temporary lockdown</h2>
            {onLockdown && (
              <button disabled={busy} onClick={onLockdown}>
                Manage
              </button>
            )}
          </div>
          <div className="lockdown-item">
            <strong>{snapshot.lockdown.groupNames.join(", ")}</strong>
            <span>Ends {duration(snapshot.lockdown.endsAt)}</span>
          </div>
          <p>
            Holds these groups on outside their normal schedules.{" "}
            {snapshot.lockdown.detail}
          </p>
        </section>
      )}
      <div className="dashboard-columns">
        {groupsPanel}
        {retreatsPanel}
      </div>
      {!compact && (
        <div className="dashboard-actions">
          <button className="primary" disabled={!onNew || busy} onClick={onNew}>
            New blocking group
          </button>
          {presets.length > 0 && total > 0 && (
            <PresetMenu
              presets={presets}
              disabled={busy}
              onPick={(p) => onPreset?.(p)}
            />
          )}
          <span className="spacer" />
          <button disabled={!onLockdown || busy} onClick={onLockdown}>
            {snapshot.lockdown ? "Manage lockdowns" : "Lockdown"}
          </button>
          <button onClick={onRetreats}>
            All retreats · {planned.length} planned
          </button>
        </div>
      )}
      {total > 0 && (
        <ScheduleLanes
          snapshot={snapshot}
          onSelect={(id) => {
            const g = snapshot.groups.find((v) => v.id === id);
            if (g) edit(g);
            else onRetreats();
          }}
        />
      )}
      <BypassPanel
        snapshot={snapshot}
        compact={compact}
        onHistory={onHistory}
      />
      {compact && (
        <p className="sync-footer">
          {snapshot.platform === "ios" || snapshot.platform === "macos"
            ? "iCloud"
            : "Sync"}{" "}
          · {snapshot.sync.detail}
        </p>
      )}
    </>
  );
}
