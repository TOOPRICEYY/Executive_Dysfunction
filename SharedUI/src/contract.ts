/** Presentation contract, NOT a policy store or enforcement authority.
 * Dates are ISO-8601 UTC; windows use local civil time, Sunday=1 (Apple convention).
 * Hosts translate their existing models at this boundary, not in view components.
 */
export const protocolVersion = 1;
export type Capability =
  | "editGroups"
  | "temporaryAccess"
  | "retreats"
  | "lockdown"
  | "pickApplications"
  | "diagnostics"
  | "appearance"
  | "advancedControls"
  | "enforcementControl"
  | "presets";
export interface Slot {
  id: string;
  weekdays: number[];
  startMinutes: number;
  endMinutes: number;
}
export interface ChangePolicy {
  kind: "none" | "passage" | "delay" | "checkpoints" | "inherited";
  words: number;
  delayDays: number;
}
export interface TemporaryPolicy {
  allowed: boolean;
  words: number;
  maximumMinutes: number;
  resetDays: number | null;
}
/** Host-evaluated "what is this group doing now" (GroupNowStatus on Apple). */
export type NowState =
  | "lockdown"
  | "paused"
  | "blocking"
  | "upcoming"
  | "idle"
  | "off";
export interface GroupNow {
  state: NowState;
  /** When the state next changes, if known. */
  changesAt?: string;
  /** Ready-to-show sentence, e.g. "Next block · tomorrow 09:00". */
  headline: string;
}
/** Host-evaluated progress of an edit unlock. */
export interface UnlockState {
  phase: "idle" | "waiting" | "confirmationDue" | "unlocked" | "cancelled";
  /** waiting: opens at; confirmationDue: deadline; unlocked: window closes at. */
  at?: string;
}
/** A group in force only because a running Retreat (or lockdown) holds it. Read-only here. */
export interface RetreatGroup {
  id: string;
  name: string;
  now: GroupNow;
  lock: ChangePolicy["kind"];
  delayDays: number;
  targets: string;
}
/** Concrete blocked intervals for one local day, evaluated by the host (DST, retreats, lockdowns). */
export interface ScheduleDay {
  start: string;
  end: string;
  lanes: { id: string; intervals: { start: string; end: string }[] }[];
}
export interface Preset {
  id: string;
  name: string;
  summary: string;
  lock: ChangePolicy["kind"];
}
export interface Group {
  id: string;
  name: string;
  enabled: boolean;
  domains: string[];
  applications: string[];
  applicationSummary?: string;
  selectionToken?: string;
  schedule: { mode: "block" | "allow"; slots: Slot[] };
  changePolicy: ChangePolicy;
  temporaryPolicy: TemporaryPolicy;
  temporaryPassageWords?: number;
  // Authoritative host-derived state. The UI must not infer enforcement from a schedule.
  status:
    | "blocking"
    | "allowed"
    | "suspended"
    | "disabled"
    | "unsupported"
    | "lockdown";
  detail: string;
  suspendedUntil?: string;
  canEdit: boolean;
  now?: GroupNow;
  unlock?: UnlockState;
  lockdownUntil?: string;
}
export interface Retreat {
  id: string;
  name: string;
  startsAt: string;
  endsAt: string;
  state: "draft" | "scheduled" | "active" | "completed" | "cancelled";
  version: number;
  groupNames: string[];
  changePolicyLabel: string;
  canRequestEnd: boolean;
}
export interface Bypass {
  id: string;
  groupID: string;
  groupName: string;
  startedAt: string;
  endsAt: string;
  reason: "conscious" | "edulgence" | "unspecified";
}
export interface Snapshot {
  schema: 1;
  revision: string;
  platform: "windows" | "macos" | "ios" | "preview";
  capabilities: Capability[];
  appearance?: { theme: string; accent: string };
  enforcementEnabled?: boolean;
  enforcement: {
    state: "active" | "disabled" | "error" | "unknown";
    title: string;
    detail: string;
    /** Short banner word(s), e.g. "WEB FILTER ON". Falls back to title. */
    headline?: string;
  };
  /** Host summary (DashboardNowSummary). Absent: the UI shows a neutral heading. */
  summary?: { headline: string; next: string | null };
  retreatGroups?: RetreatGroup[];
  /** Seven local days starting today. */
  schedule?: { days: ScheduleDay[] };
  presets?: Preset[];
  sync: { state: "current" | "pending" | "unavailable"; detail: string };
  groups: Group[];
  retreats: Retreat[];
  bypasses: Bypass[];
  lockdown: null | { endsAt: string; groupNames: string[]; detail: string };
}
export type Command =
  | { type: "snapshot" }
  | { type: "openAdvancedControls" }
  | { type: "setAppearance"; key: "theme" | "accent"; value: string }
  | { type: "setEnforcement"; revision: string; enabled: boolean }
  | { type: "submitChallenge"; challengeID: string; typed: string }
  | { type: "cancelTemporaryAccess"; revision: string; groupID: string }
  | { type: "saveGroup"; revision: string; group: Group }
  | { type: "deleteGroup"; revision: string; groupID: string }
  | {
      type: "requestTemporaryAccess";
      revision: string;
      groupID: string;
      minutes: number;
      reason: Exclude<Bypass["reason"], "unspecified">;
      reflection?: string;
    }
  | { type: "requestGroupUnlock"; revision: string; groupID: string }
  | { type: "requestRetreatEnd"; revision: string; retreatID: string }
  | { type: "createRetreat"; revision: string }
  | { type: "startLockdown"; revision: string }
  | { type: "installPreset"; revision: string; presetID: string }
  | { type: "pickApplications"; groupID: string }
  | { type: "diagnostics" };
export interface Reply {
  snapshot?: Snapshot;
  applications?: string[];
  applicationSummary?: string;
  selectionToken?: string;
  message?: string;
  challenge?: Challenge;
}
export interface Challenge {
  id: string;
  title: string;
  passage: string;
  expiresAt: string;
  detail: string;
}
export function isChallenge(value: unknown): value is Challenge {
  if (!value || typeof value !== "object") return false;
  const c = value as Challenge;
  return (
    typeof c.id === "string" &&
    typeof c.title === "string" &&
    typeof c.detail === "string" &&
    typeof c.passage === "string" &&
    c.passage.length > 0 &&
    c.passage.length <= 400000 &&
    typeof c.expiresAt === "string" &&
    Number.isFinite(Date.parse(c.expiresAt))
  );
}
export interface Adapter {
  send(command: Command): Promise<Reply>;
  dispose(): void;
}
export interface RequestEnvelope {
  version: 1;
  id: string;
  command: Command;
}
export interface ReplyEnvelope {
  version: 1;
  id: string;
  ok: boolean;
  result?: Reply;
  error?: string;
}

const states = new Set(["active", "disabled", "error", "unknown"]);
/** Reject incomplete/mismatched hosts, instead of presenting "enabled" from arbitrary JSON. */
export function isSnapshot(value: unknown): value is Snapshot {
  if (!value || typeof value !== "object") return false;
  const s = value as Snapshot;
  return (
    s.schema === 1 &&
    typeof s.revision === "string" &&
    ["windows", "macos", "ios", "preview"].includes(s.platform) &&
    Array.isArray(s.capabilities) &&
    s.capabilities.every((v) => typeof v === "string") &&
    (s.appearance === undefined ||
      (!!s.appearance &&
        ["light", "dark", "system"].includes(s.appearance.theme) &&
        [
          "themeDefault",
          "yellow",
          "green",
          "blue",
          "orange",
          "magenta",
          "violet",
        ].includes(s.appearance.accent))) &&
    !!s.enforcement &&
    states.has(s.enforcement.state) &&
    typeof s.enforcement.title === "string" &&
    typeof s.enforcement.detail === "string" &&
    !!s.sync &&
    ["current", "pending", "unavailable"].includes(s.sync.state) &&
    typeof s.sync.detail === "string" &&
    Array.isArray(s.groups) &&
    s.groups.every(isGroup) &&
    Array.isArray(s.retreats) &&
    s.retreats.every(
      (r) =>
        !!r &&
        typeof r === "object" &&
        typeof r.id === "string" &&
        typeof r.name === "string" &&
        isDate(r.startsAt) &&
        isDate(r.endsAt) &&
        Array.isArray(r.groupNames) &&
        r.groupNames.every((n) => typeof n === "string") &&
        typeof r.changePolicyLabel === "string" &&
        ["draft", "scheduled", "active", "completed", "cancelled"].includes(
          r.state,
        ) &&
        Number.isInteger(r.version) &&
        typeof r.canRequestEnd === "boolean",
    ) &&
    Array.isArray(s.bypasses) &&
    s.bypasses.every(
      (b) =>
        !!b &&
        typeof b === "object" &&
        typeof b.id === "string" &&
        typeof b.groupID === "string" &&
        typeof b.groupName === "string" &&
        isDate(b.startedAt) &&
        isDate(b.endsAt) &&
        ["conscious", "edulgence", "unspecified"].includes(b.reason),
    ) &&
    (s.enforcement.headline === undefined ||
      typeof s.enforcement.headline === "string") &&
    (s.summary === undefined ||
      (!!s.summary &&
        typeof s.summary.headline === "string" &&
        (s.summary.next === null || typeof s.summary.next === "string"))) &&
    (s.retreatGroups === undefined ||
      (Array.isArray(s.retreatGroups) &&
        s.retreatGroups.every(
          (r) =>
            !!r &&
            typeof r.id === "string" &&
            typeof r.name === "string" &&
            isNow(r.now) &&
            policyKinds.includes(r.lock) &&
            integer(r.delayDays, 0, 365) &&
            typeof r.targets === "string",
        ))) &&
    (s.schedule === undefined ||
      (!!s.schedule &&
        Array.isArray(s.schedule.days) &&
        s.schedule.days.length <= 14 &&
        s.schedule.days.every(
          (d) =>
            !!d &&
            isDate(d.start) &&
            isDate(d.end) &&
            Array.isArray(d.lanes) &&
            d.lanes.every(
              (l) =>
                !!l &&
                typeof l.id === "string" &&
                Array.isArray(l.intervals) &&
                l.intervals.every(
                  (i) => !!i && isDate(i.start) && isDate(i.end),
                ),
            ),
        ))) &&
    (s.presets === undefined ||
      (Array.isArray(s.presets) &&
        s.presets.every(
          (p) =>
            !!p &&
            typeof p.id === "string" &&
            typeof p.name === "string" &&
            typeof p.summary === "string" &&
            policyKinds.includes(p.lock),
        ))) &&
    (s.lockdown === null ||
      (!!s.lockdown &&
        isDate(s.lockdown.endsAt) &&
        typeof s.lockdown.detail === "string" &&
        Array.isArray(s.lockdown.groupNames) &&
        s.lockdown.groupNames.every((n) => typeof n === "string")))
  );
}
const integer = (n: unknown, min: number, max: number) =>
  typeof n === "number" && Number.isInteger(n) && n >= min && n <= max;
const strings = (v: unknown): v is string[] =>
  Array.isArray(v) && v.every((s) => typeof s === "string");
const isDate = (v: unknown) =>
  typeof v === "string" && Number.isFinite(Date.parse(v));
const policyKinds = ["none", "passage", "delay", "checkpoints", "inherited"];
function isNow(n: unknown): n is GroupNow {
  if (!n || typeof n !== "object") return false;
  const v = n as GroupNow;
  return (
    ["lockdown", "paused", "blocking", "upcoming", "idle", "off"].includes(
      v.state,
    ) &&
    typeof v.headline === "string" &&
    (v.changesAt === undefined || isDate(v.changesAt))
  );
}
export function isGroup(g: unknown): g is Group {
  if (!g || typeof g !== "object") return false;
  const v = g as Group;
  return (
    typeof v.id === "string" &&
    typeof v.name === "string" &&
    typeof v.enabled === "boolean" &&
    strings(v.domains) &&
    strings(v.applications) &&
    typeof v.canEdit === "boolean" &&
    (v.temporaryPassageWords === undefined ||
      integer(v.temporaryPassageWords, 20, 38400)) &&
    [
      "blocking",
      "allowed",
      "suspended",
      "disabled",
      "unsupported",
      "lockdown",
    ].includes(v.status) &&
    typeof v.detail === "string" &&
    (v.suspendedUntil === undefined || isDate(v.suspendedUntil)) &&
    (v.lockdownUntil === undefined || isDate(v.lockdownUntil)) &&
    (v.now === undefined || isNow(v.now)) &&
    (v.unlock === undefined ||
      (!!v.unlock &&
        typeof v.unlock === "object" &&
        [
          "idle",
          "waiting",
          "confirmationDue",
          "unlocked",
          "cancelled",
        ].includes(v.unlock.phase) &&
        (v.unlock.at === undefined || isDate(v.unlock.at)))) &&
    !!v.schedule &&
    ["block", "allow"].includes(v.schedule.mode) &&
    Array.isArray(v.schedule.slots) &&
    v.schedule.slots.every(
      (s) =>
        !!s &&
        typeof s === "object" &&
        typeof s.id === "string" &&
        Array.isArray(s.weekdays) &&
        s.weekdays.every((d) => integer(d, 1, 7)) &&
        integer(s.startMinutes, 0, 1439) &&
        integer(s.endMinutes, 0, 1440),
    ) &&
    !!v.changePolicy &&
    policyKinds.includes(v.changePolicy.kind) &&
    integer(v.changePolicy.words, 20, 300) &&
    integer(v.changePolicy.delayDays, 0, 365) &&
    !!v.temporaryPolicy &&
    typeof v.temporaryPolicy.allowed === "boolean" &&
    integer(v.temporaryPolicy.words, 20, 300) &&
    integer(v.temporaryPolicy.maximumMinutes, 1, 1440) &&
    (v.temporaryPolicy.resetDays === null ||
      integer(v.temporaryPolicy.resetDays, 1, 365))
  );
}
