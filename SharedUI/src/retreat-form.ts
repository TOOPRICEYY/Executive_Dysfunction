import type { ChangePolicy, Retreat, RetreatDraft } from "./contract.ts";

const pad = (n: number) => String(n).padStart(2, "0");

/** An ISO instant as the value of a `datetime-local` input, in local time. */
export function toLocalInput(iso: string): string {
  const d = new Date(iso);
  if (!Number.isFinite(d.getTime())) return "";
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}T${pad(d.getHours())}:${pad(d.getMinutes())}`;
}

/**
 * A `datetime-local` value (local civil time) as ISO-8601 UTC without
 * fractional seconds, or null when it is not a complete, real date and time.
 */
export function fromLocalInput(value: string): string | null {
  const m = /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2})(?::(\d{2}))?$/.exec(
    value,
  );
  if (!m) return null;
  const [y, mo, d, h, mi, s] = m.slice(1).map((v) => Number(v ?? 0));
  const date = new Date(y, mo - 1, d, h, mi, s);
  // Reject values the Date constructor would roll over, e.g. 31 February.
  if (
    date.getFullYear() !== y ||
    date.getMonth() !== mo - 1 ||
    date.getDate() !== d ||
    date.getHours() !== h ||
    date.getMinutes() !== mi
  )
    return null;
  return date.toISOString().replace(/\.\d{3}Z$/, "Z");
}

/** What the form edits: dates stay as local input values until saved. */
export interface RetreatForm {
  id?: string;
  name: string;
  goal: string;
  start: string;
  end: string;
  groupIDs: string[];
  changePolicy: ChangePolicy;
  startNow: boolean;
}

/** Matches the native default for a new retreat: wait three days, then type 40 words. */
export function newRetreatForm(now = new Date()): RetreatForm {
  const start = new Date(now);
  start.setSeconds(0, 0);
  const end = new Date(start);
  end.setDate(end.getDate() + 30);
  return {
    name: "",
    goal: "",
    start: toLocalInput(start.toISOString()),
    end: toLocalInput(end.toISOString()),
    groupIDs: [],
    changePolicy: { kind: "delay", words: 40, delayDays: 3 },
    startNow: false,
  };
}

export function retreatFormFrom(retreat: Retreat): RetreatForm {
  return {
    id: retreat.id,
    name: retreat.name,
    goal: retreat.goal ?? "",
    start: toLocalInput(retreat.startsAt),
    end: toLocalInput(retreat.endsAt),
    groupIDs: retreat.groupIDs ?? [],
    changePolicy: retreat.changePolicy ?? {
      kind: "delay",
      words: 40,
      delayDays: 3,
    },
    startNow: false,
  };
}

/** The first obvious problem, or "" when the host may be asked. */
export function retreatProblem(form: RetreatForm): string {
  if (!form.name.trim()) return "Name the retreat.";
  if (!form.groupIDs.length) return "Choose at least one Blocking Group.";
  const start = fromLocalInput(form.start);
  const end = fromLocalInput(form.end);
  if (!start || !end) return "Choose when the retreat starts and ends.";
  if (Date.parse(end) <= Date.parse(start))
    return "The retreat has to end after it starts.";
  const { words, delayDays, kind } = form.changePolicy;
  if (
    kind !== "none" &&
    !(Number.isInteger(words) && words >= 20 && words <= 300)
  )
    return "Choose a passage of 20 to 300 words.";
  if (
    (kind === "delay" || kind === "checkpoints") &&
    !(Number.isInteger(delayDays) && delayDays >= 0 && delayDays <= 365)
  )
    return "Choose a wait of up to 365 days.";
  return "";
}

/** The command payload. Call only when `retreatProblem` is "". */
export function retreatDraft(form: RetreatForm): RetreatDraft {
  const { kind } = form.changePolicy;
  return {
    ...(form.id ? { id: form.id } : {}),
    name: form.name.trim(),
    goal: form.goal.trim(),
    startsAt: fromLocalInput(form.start)!,
    endsAt: fromLocalInput(form.end)!,
    groupIDs: form.groupIDs,
    changePolicy: {
      kind,
      words: form.changePolicy.words,
      // Only waiting policies carry a wait; the native editor stores none otherwise.
      delayDays:
        kind === "delay" || kind === "checkpoints"
          ? form.changePolicy.delayDays
          : 0,
    },
    startNow: form.startNow,
  };
}
