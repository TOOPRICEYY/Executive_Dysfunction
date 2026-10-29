import type {
  Adapter,
  Snapshot,
  Group,
  GroupNow,
  Preset,
  ScheduleDay,
  Slot,
} from "./contract.ts";
import { daySegments, moment } from "./presentation.ts";
/** Explicit, in-memory UI fixture. Never imported by a native policy engine.
 * No localStorage persistence, native commands, iCloud or enforcement side effects.
 * The tiny schedule evaluator below exists only so the fixture can fill the same
 * host-evaluated fields (now, summary, schedule) a real host sends.
 */

const DAY = 86_400_000;
const at = (day: Date, minutes: number) =>
  new Date(day.getFullYear(), day.getMonth(), day.getDate(), 0, minutes);
const startOfDay = (d: Date) =>
  new Date(d.getFullYear(), d.getMonth(), d.getDate());

/** Fixture-only equivalent of effectiveBlockingSlots(): allowance windows invert. */
function blockingSlots(g: Group): Slot[] {
  if (g.schedule.mode === "block") return g.schedule.slots;
  const out: Slot[] = [];
  for (let d = 1; d <= 7; d++) {
    const allowed = daySegments(g.schedule.slots, d).sort(
      (a, b) => a[0] - b[0],
    );
    let cursor = 0;
    for (const [s, e] of allowed) {
      if (s > cursor)
        out.push({
          id: `${d}-${cursor}`,
          weekdays: [d],
          startMinutes: cursor,
          endMinutes: s,
        });
      cursor = Math.max(cursor, e);
    }
    if (cursor < 1440)
      out.push({
        id: `${d}-${cursor}`,
        weekdays: [d],
        startMinutes: cursor,
        endMinutes: 1440,
      });
  }
  return out;
}
function intervals(slots: Slot[], from: Date, to: Date): [number, number][] {
  const raw: [number, number][] = [];
  for (
    let day = new Date(startOfDay(from).getTime() - DAY);
    day < to;
    day = new Date(day.getFullYear(), day.getMonth(), day.getDate() + 1)
  ) {
    const weekday = day.getDay() + 1;
    for (const s of slots) {
      if (!s.weekdays.includes(weekday)) continue;
      const start = at(day, s.startMinutes).getTime();
      const endDay =
        s.endMinutes > s.startMinutes
          ? day
          : new Date(day.getFullYear(), day.getMonth(), day.getDate() + 1);
      const end = at(endDay, s.endMinutes).getTime();
      if (end > start) raw.push([start, end]);
    }
  }
  raw.sort((a, b) => a[0] - b[0]);
  const merged: [number, number][] = [];
  for (const i of raw) {
    const last = merged[merged.length - 1];
    if (last && i[0] <= last[1]) last[1] = Math.max(last[1], i[1]);
    else merged.push([...i]);
  }
  return merged
    .map(
      ([s, e]) =>
        [Math.max(s, from.getTime()), Math.min(e, to.getTime())] as [
          number,
          number,
        ],
    )
    .filter(([s, e]) => s < e);
}
function evaluate(g: Group, now: Date): GroupNow {
  const iso = (t: number) => new Date(t).toISOString();
  if (g.lockdownUntil && Date.parse(g.lockdownUntil) > now.getTime())
    return {
      state: "lockdown",
      changesAt: g.lockdownUntil,
      headline: `Locked down · until ${moment(g.lockdownUntil, now)}`,
    };
  if (!g.enabled) return { state: "off", headline: "Off" };
  const horizon = new Date(now.getTime() + 8 * DAY);
  const list = intervals(blockingSlots(g), now, horizon);
  if (g.suspendedUntil && Date.parse(g.suspendedUntil) > now.getTime()) {
    return {
      state: "paused",
      changesAt: g.suspendedUntil,
      headline: `Paused · blocks again ${moment(g.suspendedUntil, now, true)}`,
    };
  }
  const current = list.find(
    ([s, e]) => s <= now.getTime() && now.getTime() < e,
  );
  if (current)
    return current[1] >= horizon.getTime()
      ? { state: "blocking", headline: "Blocking now · always on" }
      : {
          state: "blocking",
          changesAt: iso(current[1]),
          headline: `Blocking now · until ${moment(iso(current[1]), now)}`,
        };
  const next = list.find(([s]) => s > now.getTime());
  if (next)
    return {
      state: "upcoming",
      changesAt: iso(next[0]),
      headline: `Next block · ${moment(iso(next[0]), now)}`,
    };
  return { state: "idle", headline: "No blocks in the next week" };
}
function summary(groups: Group[], now: Date): Snapshot["summary"] {
  const states = groups.map((g) => ({ name: g.name, now: g.now! }));
  const blocking = states.filter(
    (s) => s.now.state === "blocking" || s.now.state === "lockdown",
  ).length;
  const paused = states.filter((s) => s.now.state === "paused").length;
  const plural = (n: number) => `${n} ${n === 1 ? "group" : "groups"}`;
  const headline = blocking
    ? `${plural(blocking)} blocking now`
    : paused
      ? `${plural(paused)} paused`
      : "Nothing is blocked right now";
  const next = states
    .filter((s) => s.now.changesAt)
    .sort(
      (a, b) => Date.parse(a.now.changesAt!) - Date.parse(b.now.changesAt!),
    )[0];
  if (!next) return { headline, next: null };
  const verb =
    next.now.state === "upcoming"
      ? "starts"
      : next.now.state === "paused"
        ? "resumes"
        : "ends";
  return {
    headline,
    next: `Next: ${next.name} ${verb} ${moment(next.now.changesAt!, now, true)}`,
  };
}
function schedule(groups: Group[], now: Date): { days: ScheduleDay[] } {
  const today = startOfDay(now);
  return {
    days: Array.from({ length: 7 }, (_, i) => {
      const start = new Date(
        today.getFullYear(),
        today.getMonth(),
        today.getDate() + i,
      );
      const end = new Date(
        today.getFullYear(),
        today.getMonth(),
        today.getDate() + i + 1,
      );
      return {
        start: start.toISOString(),
        end: end.toISOString(),
        lanes: groups.map((g) => {
          const list = g.enabled ? intervals(blockingSlots(g), start, end) : [];
          if (g.lockdownUntil) {
            const e = Math.min(Date.parse(g.lockdownUntil), end.getTime()),
              s = Math.max(now.getTime(), start.getTime());
            if (s < e) list.push([s, e]);
          }
          return {
            id: g.id,
            intervals: list.map(([s, e]) => ({
              start: new Date(s).toISOString(),
              end: new Date(e).toISOString(),
            })),
          };
        }),
      };
    }),
  };
}
const presets: Preset[] = [
  {
    id: "work-hours",
    name: "Work hours",
    summary: "Weekdays 9–5. Passage to change, up to 1 hour of extra time.",
    lock: "passage",
  },
  {
    id: "evenings-off",
    name: "Evenings off",
    summary: "Every night 21:00–07:00, so the phone and laptop wind down.",
    lock: "delay",
  },
  {
    id: "deep-work",
    name: "Deep-work retreat",
    summary: "All day, every day, while a Retreat runs. No extra time.",
    lock: "delay",
  },
  {
    id: "hard-block",
    name: "Hard block",
    summary: "Always on. Changes need a week and daily confirmations.",
    lock: "checkpoints",
  },
];
/** Re-evaluate time-dependent host fields, as a native host does on every read. */
function refresh(state: Snapshot): Snapshot {
  const now = new Date();
  const s = structuredClone(state);
  for (const g of s.groups) {
    g.now = evaluate(g, now);
    if (g.status !== "unsupported")
      g.status = (
        {
          lockdown: "lockdown",
          blocking: "blocking",
          paused: "suspended",
          off: "disabled",
          upcoming: "allowed",
          idle: "allowed",
        } as const
      )[g.now.state];
    if (g.status !== "unsupported") g.detail = g.now.headline;
  }
  s.summary = summary(s.groups, now);
  s.schedule = schedule(s.groups, now);
  return s;
}

export function previewSnapshot(): Snapshot {
  const hour = new Date().getHours();
  const group = (
    id: string,
    name: string,
    domains: string[],
    slots: Omit<Slot, "id">[],
    kind: Group["changePolicy"]["kind"],
    extra: Partial<Group> = {},
  ): Group => ({
    id,
    name,
    domains,
    applications: [],
    enabled: true,
    status: "allowed",
    canEdit: kind === "none",
    detail: "Example state · no actual blocking",
    schedule: {
      mode: "block",
      slots: slots.map((s, i) => ({ ...s, id: `${id}-${i}` })),
    },
    changePolicy: { kind, words: 40, delayDays: kind === "delay" ? 1 : 0 },
    temporaryPolicy: {
      allowed: true,
      words: 40,
      maximumMinutes: 60,
      resetDays: 7,
    },
    unlock: kind === "none" ? undefined : { phase: "idle" },
    ...extra,
  });
  return refresh({
    schema: 1,
    revision: "preview-1",
    platform: "preview",
    capabilities: ["editGroups", "presets"],
    enforcement: {
      state: "disabled",
      title: "Interface preview",
      headline: "Interface preview",
      detail:
        "Sample data only. No sites or apps are being blocked by this preview.",
    },
    sync: {
      state: "unavailable",
      detail:
        "Preview is isolated. Your real groups and devices are unchanged.",
    },
    groups: [
      group(
        "news",
        "News & opinion",
        ["news.ycombinator.com", "reddit.com"],
        [
          {
            weekdays: [1, 2, 3, 4, 5, 6, 7],
            startMinutes: Math.max(0, hour - 1) * 60,
            endMinutes: Math.min(24, hour + 2) * 60,
          },
        ],
        "passage",
      ),
      group(
        "social",
        "Social feeds",
        ["x.com", "instagram.com"],
        [
          {
            weekdays: [2, 3, 4, 5, 6],
            startMinutes: 9 * 60,
            endMinutes: 17 * 60,
          },
          {
            weekdays: [1, 2, 3, 4, 5, 6, 7],
            startMinutes: 21 * 60,
            endMinutes: 7 * 60,
          },
        ],
        "delay",
        { suspendedUntil: new Date(Date.now() + 18 * 60_000).toISOString() },
      ),
      group(
        "video",
        "Video",
        ["youtube.com"],
        [{ weekdays: [1, 7], startMinutes: 18 * 60, endMinutes: 23 * 60 }],
        "none",
      ),
    ],
    retreats: [
      {
        id: "retreat",
        name: "A quieter month",
        startsAt: new Date(Date.now() - DAY).toISOString(),
        endsAt: new Date(Date.now() + 27 * DAY).toISOString(),
        state: "active",
        version: 2,
        groupNames: ["News & opinion", "Social feeds"],
        changePolicyLabel: "Passage + 3-day wait",
        canRequestEnd: false,
      },
    ],
    bypasses: [
      {
        id: "bypass-1",
        groupID: "social",
        groupName: "Social feeds",
        startedAt: new Date(Date.now() - 12 * 60_000).toISOString(),
        endsAt: new Date(Date.now() + 18 * 60_000).toISOString(),
        reason: "conscious",
      },
    ],
    lockdown: null,
    presets,
  });
}
/** Original native preview data for like-for-like layout comparison only. */
export function nativeReferenceSnapshot(): Snapshot {
  const state = previewSnapshot();
  state.groups = [
    {
      name: "Social Feeds",
      domains: ["twitter.com", "instagram.com"],
      weekdays: [2, 3, 4, 5, 6],
      start: 1080,
      end: 1320,
    },
    {
      name: "News",
      domains: ["news.ycombinator.com"],
      weekdays: [7, 1],
      start: 960,
      end: 1200,
    },
    {
      name: "Video",
      domains: ["youtube.com"],
      weekdays: [1],
      start: 1080,
      end: 1380,
    },
  ].map((g, i) => ({
    ...state.groups[i],
    id: `native-${i}`,
    name: g.name,
    domains: g.domains,
    status: "allowed",
    suspendedUntil: undefined,
    unlock: undefined,
    canEdit: true,
    temporaryPolicy: { ...state.groups[i].temporaryPolicy, allowed: false },
    changePolicy: { kind: "none", words: 20, delayDays: 0 },
    schedule: {
      mode: "block",
      slots: [
        {
          id: `native-slot-${i}`,
          weekdays: g.weekdays,
          startMinutes: g.start,
          endMinutes: g.end,
        },
      ],
    },
  }));
  state.retreats = [];
  state.bypasses = [];
  state.enforcement = {
    state: "disabled",
    title: "Not installed",
    headline: "Not installed",
    detail: "UI preview — enforcement untouched",
  };
  state.sync = {
    state: "unavailable",
    detail: "UI preview — enforcement untouched",
  };
  return refresh(state);
}
export function createPreviewAdapter(reference = false): Adapter {
  let state = reference ? nativeReferenceSnapshot() : previewSnapshot(),
    revision = 1;
  const reply = () => (state = refresh(state));
  return {
    async send(command) {
      if (command.type === "snapshot") return { snapshot: reply() };
      if (
        command.type === "saveGroup" ||
        command.type === "deleteGroup" ||
        command.type === "installPreset"
      ) {
        if (command.revision !== state.revision)
          throw new Error("This view is out of date. Refresh before saving.");
        if (command.type === "saveGroup") {
          const group = {
            ...structuredClone(command.group),
            status: "unsupported" as const,
            detail: "Saved in this preview only. Not enforced.",
          };
          const index = state.groups.findIndex((g) => g.id === group.id);
          if (index >= 0) state.groups[index] = group;
          else state.groups.push(group);
        } else if (command.type === "installPreset") {
          const p = presets.find((v) => v.id === command.presetID);
          if (!p) throw new Error("Unknown preset.");
          const [start, end, days] =
            p.id === "work-hours"
              ? [540, 1020, [2, 3, 4, 5, 6]]
              : p.id === "evenings-off"
                ? [1260, 420, [1, 2, 3, 4, 5, 6, 7]]
                : [0, 1440, [1, 2, 3, 4, 5, 6, 7]];
          state.groups.push({
            id: crypto.randomUUID(),
            name: p.name,
            enabled: true,
            domains: ["example.com"],
            applications: [],
            schedule: {
              mode: "block",
              slots: [
                {
                  id: crypto.randomUUID(),
                  weekdays: days as number[],
                  startMinutes: start as number,
                  endMinutes: end as number,
                },
              ],
            },
            changePolicy: {
              kind: p.lock,
              words: 40,
              delayDays:
                p.lock === "delay" ? 1 : p.lock === "checkpoints" ? 7 : 0,
            },
            temporaryPolicy: {
              allowed: p.id === "work-hours",
              words: 40,
              maximumMinutes: 60,
              resetDays: null,
            },
            status: "unsupported",
            detail: "Saved in this preview only. Not enforced.",
            canEdit: true,
          });
        } else
          state.groups = state.groups.filter((g) => g.id !== command.groupID);
        state = { ...state, revision: `preview-${++revision}` };
        return {
          snapshot: reply(),
          message: "Preview updated. No device settings changed.",
        };
      }
      throw new Error(
        "This operation requires a connected native policy engine; it is not simulated.",
      );
    },
    dispose() {},
  };
}
