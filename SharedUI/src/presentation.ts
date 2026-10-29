import type {
  Bypass,
  ChangePolicy,
  Group,
  GroupNow,
  NowState,
  RetreatGroup,
  Slot,
  Snapshot,
} from "./contract.ts";
/** Never infer active enforcement from saved schedules or sample data.
 * The host's summary (evaluated by its own schedule engine) is used only while
 * enforcement is confirmed; otherwise the heading says what needs attention. */
export function nowHeadline(snapshot: Snapshot): string {
  const confirmed =
    snapshot.platform === "preview" || snapshot.enforcement.state === "active";
  if (snapshot.summary && confirmed) return snapshot.summary.headline;
  if (snapshot.platform === "preview") return "Your day at a glance";
  if (
    snapshot.enforcement.state === "unknown" ||
    snapshot.enforcement.state === "error"
  )
    return "Check device enforcement";
  if (snapshot.enforcement.state === "disabled") return "Enforcement is paused";
  const blocked = snapshot.groups.filter(
    (g) => g.status === "blocking" || g.status === "lockdown",
  ).length;
  return blocked
    ? `${blocked} ${blocked === 1 ? "group is" : "groups are"} blocking now`
    : "Nothing is blocked right now";
}
export const days = [
  { id: 2, name: "Mon" },
  { id: 3, name: "Tue" },
  { id: 4, name: "Wed" },
  { id: 5, name: "Thu" },
  { id: 6, name: "Fri" },
  { id: 7, name: "Sat" },
  { id: 1, name: "Sun" },
];
export function clock(minutes: number): string {
  return `${Math.floor(minutes / 60)
    .toString()
    .padStart(2, "0")}:${(minutes % 60).toString().padStart(2, "0")}`;
}
/** Drawing only. Native engines own schedule evaluation, DST, clocks and enforcement. */
export function daySegments(slots: Slot[], day: number): [number, number][] {
  const segments: [number, number][] = [];
  for (const slot of slots) {
    for (const startDay of new Set(slot.weekdays)) {
      if (slot.startMinutes < slot.endMinutes) {
        if (startDay === day)
          segments.push([slot.startMinutes, slot.endMinutes]);
      } else {
        if (startDay === day) segments.push([slot.startMinutes, 1440]);
        if ((startDay % 7) + 1 === day && slot.endMinutes > 0)
          segments.push([0, slot.endMinutes]);
      }
    }
  }
  return segments;
}
export function policyWarning(group: Group): string | null {
  const general = group.changePolicy,
    temporary = group.temporaryPolicy;
  if (!temporary.allowed) return null;
  if (general.kind === "inherited")
    return "Change protection inherits the app default. Check its native settings before comparing it with this group's temporary-access policy.";
  if (general.kind === "none")
    return "Changing this group needs no confirmation, but temporary access requires a passage. Permanent changes are easier than a temporary exception.";
  if (
    (general.kind === "passage" || general.delayDays === 0) &&
    general.words <= temporary.words
  )
    return "The change policy is no harder than temporary access, but can remove restrictions permanently.";
  if (general.kind === "passage" && temporary.resetDays !== null)
    return "Passage backoff may eventually make temporary access harder than permanently changing this group.";
  return null;
}
export function bypassCounts(
  events: Bypass[],
  since: number,
): { groupID: string; name: string; count: number }[] {
  const counts = new Map<
    string,
    { groupID: string; name: string; count: number }
  >();
  for (const event of events) {
    if (Date.parse(event.startedAt) < since) continue;
    const current = counts.get(event.groupID) ?? {
      groupID: event.groupID,
      name: event.groupName,
      count: 0,
    };
    current.count++;
    counts.set(event.groupID, current);
  }
  return [...counts.values()].sort(
    (a, b) => b.count - a.count || a.name.localeCompare(b.name),
  );
}

/** "Next: Social Feeds starts at 18:00", or a fallback. */
export function nextLine(snapshot: Snapshot): string {
  if (snapshot.summary)
    return snapshot.summary.next ?? "No changes scheduled in the next week.";
  return snapshot.platform === "preview"
    ? "Sample state only — your real settings are unchanged."
    : snapshot.enforcement.detail;
}

/** Fallback when a host does not send `now`: derived from its authoritative status only. */
export function groupNow(g: Group): GroupNow {
  if (g.now) return g.now;
  const state: NowState =
    g.status === "lockdown"
      ? "lockdown"
      : g.status === "blocking"
        ? "blocking"
        : g.status === "suspended"
          ? "paused"
          : g.status === "disabled"
            ? "off"
            : "idle";
  return { state, headline: g.detail };
}
const rank: Record<NowState, number> = {
  lockdown: 0,
  blocking: 1,
  paused: 2,
  upcoming: 3,
  idle: 4,
  off: 5,
};
/** In force first, then soonest change, then name: "now, next, later". */
export function byNow<T extends { name: string }>(
  items: T[],
  now: (item: T) => GroupNow,
): T[] {
  return [...items].sort((a, b) => {
    const x = now(a),
      y = now(b);
    if (rank[x.state] !== rank[y.state]) return rank[x.state] - rank[y.state];
    const p = x.changesAt ? Date.parse(x.changesAt) : Infinity,
      q = y.changesAt ? Date.parse(y.changesAt) : Infinity;
    if (p !== q) return p - q;
    return a.name.localeCompare(b.name, undefined, { sensitivity: "base" });
  });
}
export const isBlockingState = (s: NowState) =>
  s === "blocking" || s === "lockdown";

/** Lock chip text and icon, matching the native dashboard row. */
export function lockChip(
  kind: ChangePolicy["kind"],
  delayDays: number,
): { label: string; icon: "open" | "key" | "clock" | "repeat" | "lock" } {
  switch (kind) {
    case "none":
      return { label: "No lock", icon: "open" };
    case "passage":
      return { label: "Passage", icon: "key" };
    case "delay":
      return { label: `${delayDays}-day lock`, icon: "clock" };
    case "checkpoints":
      return { label: "Daily confirm", icon: "repeat" };
    default:
      return { label: "App lock", icon: "lock" };
  }
}
export function policyName(kind: ChangePolicy["kind"]): string {
  return {
    none: "No confirmation",
    passage: "Type a passage",
    delay: "Type a passage, then wait",
    checkpoints: "Repeated confirmations",
    inherited: "App default",
  }[kind];
}
export function presetLock(kind: ChangePolicy["kind"]): string {
  return {
    none: "No lock",
    passage: "Passage to change",
    delay: "Delay + passage",
    checkpoints: "Daily confirmations",
    inherited: "App lock",
  }[kind];
}
export function targetSummary(g: Group): string {
  const parts = [
    `${g.domains.length} ${g.domains.length === 1 ? "website" : "websites"}`,
  ];
  if (g.applicationSummary) parts.push(g.applicationSummary);
  else if (g.applications.length)
    parts.push(
      `${g.applications.length} ${g.applications.length === 1 ? "app" : "apps"}`,
    );
  return parts.join(" · ");
}

/** "5h 30m", "45m", or "Free". */
export function durationText(minutes: number): string {
  if (minutes <= 0) return "Free";
  const h = Math.floor(minutes / 60),
    m = Math.round(minutes % 60);
  if (h === 0) return `${m}m`;
  return m === 0 ? `${h}h` : `${h}h ${m}m`;
}
export function sameDay(a: Date, b: Date): boolean {
  return (
    a.getFullYear() === b.getFullYear() &&
    a.getMonth() === b.getMonth() &&
    a.getDate() === b.getDate()
  );
}
/** Lane subtitle: today's live state, otherwise how long the day is blocked. */
export function laneLabel(
  now: GroupNow | undefined,
  blockedMinutes: number,
  isToday: boolean,
  today: Date,
): string {
  if (isToday && now) {
    switch (now.state) {
      case "lockdown":
        return "Locked down";
      case "blocking":
        return "Blocking";
      case "paused":
        return "Paused";
      case "off":
        return "Off";
      case "upcoming":
        if (now.changesAt && sameDay(new Date(now.changesAt), today))
          return "Later today";
        return blockedMinutes ? "Done for today" : "Not today";
      case "idle":
        return blockedMinutes ? "Done for today" : "Free today";
    }
  }
  return durationText(blockedMinutes);
}
export type LaneSource = { id: string; name: string; now?: GroupNow };
export function lanesFor(snapshot: Snapshot): LaneSource[] {
  const seen = new Set<string>();
  const out: LaneSource[] = [];
  for (const g of snapshot.groups)
    if (!seen.has(g.id)) {
      seen.add(g.id);
      out.push({ id: g.id, name: g.name, now: groupNow(g) });
    }
  for (const r of snapshot.retreatGroups ?? ([] as RetreatGroup[]))
    if (!seen.has(r.id)) {
      seen.add(r.id);
      out.push({ id: r.id, name: r.name, now: r.now });
    }
  return out;
}
/** "14:00", "tomorrow 09:00", "Fri 09:00" — matches GroupNowStatus.moment. */
export function moment(
  iso: string,
  now = new Date(),
  preposition = false,
): string {
  const d = new Date(iso);
  const time = d.toLocaleTimeString([], { hour: "numeric", minute: "2-digit" });
  if (sameDay(d, now)) return preposition ? `at ${time}` : time;
  const t = new Date(now.getFullYear(), now.getMonth(), now.getDate() + 1);
  if (sameDay(d, t)) return `tomorrow ${time}`;
  return `${d.toLocaleDateString([], { weekday: "short" })} ${time}`;
}
