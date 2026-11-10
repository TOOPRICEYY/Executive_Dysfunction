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
  | "enforcementControl"
  | "presets"
  /** The host starts a lockdown from `startLockdown` with groups and hours. */
  | "lockdownForm"
  /** The host answers `diagnostics` with the report instead of opening its own window. */
  | "diagnosticsReport"
  /** The host saves a whole retreat from `saveRetreat` instead of opening its own editor. */
  | "retreatForm"
  /** Groups carry `mode`, `categories`, `budget` and the lock window hours, and `saveGroup` applies them. */
  | "groupDetails"
  /** The host closes an unlock in progress, or an open edit window, from `cancelGroupUnlock` / `cancelRetreatUnlock`. */
  | "cancelUnlock"
  /** A running retreat can be edited; weakening edits need `requestRetreatUnlock` first. */
  | "retreatChanges"
  /** The host copies a finished retreat into a new draft from `recreateRetreat`. */
  | "recreateRetreat"
  /** `startLockdown` accepts `lock` and the durations in `lockdownOptions`. */
  | "lockdownPolicy"
  /** The host writes the diagnostic report to files from `exportDiagnostics`, using its own save surface. */
  | "diagnosticsExport"
  /** A diagnostic trace that can be recorded, exported and cleared (`debugTrace`). */
  | "debugTrace"
  /** `protection` describes app-wide protection the host can change from its commands. */
  | "protection"
  /** The host pulls and pushes synced settings from `syncNow`. */
  | "syncNow"
  /** `accessRequest` carries a request made from a block screen; answered with `answerAccessRequest`. */
  | "accessRequests"
  /** The host classifies websites on the device from `classifyWebsites`. */
  | "classifyWebsites"
  /** Groups carry `otherTargets` (Windows paths and publisher rules) and `saveGroup` applies them. */
  | "otherTargets";
/** A recovery step only the host can decide to offer, e.g. clearing a safety lock. */
export interface EnforcementAction {
  id: string;
  label: string;
  detail?: string;
  /** In progress on the host; shown disabled. */
  running?: boolean;
  /**
   * "problem" (default): shown with the problem, never hidden. "controls":
   * an ordinary step, shown with the other device controls.
   */
  placement?: "problem" | "controls";
  /** Destructive: drawn as such. The host still decides what it requires. */
  danger?: boolean;
}
export interface JournalEntry {
  at: string;
  title: string;
  detail: string;
}
export interface DiagnosticsReport {
  text: string;
  findings: {
    severity: "critical" | "warning" | "note";
    message: string;
    hint?: string;
  }[];
  /** Tamper journal, newest first: clock changes, emergency disables, removals. */
  journal?: JournalEntry[];
}
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
  /** With `groupDetails`: how long an unlock stays open, 1–72. */
  editWindowHours?: number;
  /** With `groupDetails`: how long each checkpoint may wait, 1–48. */
  confirmationWindowHours?: number;
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
  /**
   * Another group that is blocking this group's targets right now, so an idle
   * schedule does not read as an open door. Already folded into `headline`.
   * Portable targets only: Screen Time selections are opaque and cannot be
   * compared between groups.
   */
  coveredBy?: { name: string; isComplete: boolean };
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
  /** False when the host cannot confirm this group is enforced on this device. */
  enforced?: boolean;
  lock: ChangePolicy["kind"];
  delayDays: number;
  targets: string;
  /**
   * With `accessRequests`: the copy's effective temporary-access policy, so a
   * block-screen request that names it can be answered. Absent: not offered.
   */
  temporaryPolicy?: TemporaryPolicy;
  /** As `Group.temporaryPassageWords`, for this copy. */
  temporaryPassageWords?: number;
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
  /** With `groupDetails`. "allowOnly" blocks everything except the targets. */
  mode?: "block" | "allowOnly";
  /** With `groupDetails`: website categories, ids from `websiteCategories`. */
  categories?: string[];
  /** With `groupDetails`. Absent or null member: no limit. */
  budget?: { dailyMinutes?: number | null; weeklyMinutes?: number | null };
  /** Sent only after classification; the host applies it to matching websites. */
  domainCategories?: DomainCategory[];
  /** Targets for another platform's enforcement, on hosts that edit them. */
  otherTargets?: { windowsPaths: string[]; windowsPublishers: string[] };
}
export interface DomainCategory {
  domain: string;
  category: string;
  source: "appleIntelligence" | "heuristic" | "user";
}
/** App-wide change protection (the iPhone's settings lockdown). */
export interface AppLockSettings {
  enabled: boolean;
  unlockDelayDays: number;
  repeatConfirmations: boolean;
  passageWordCount: number;
  confirmationWindowHours: number;
  editWindowHours: number;
}
export interface Protection {
  /** Screen Time's deny-app-removal setting. */
  antiUninstall?: { on: boolean };
  appLock?: AppLockSettings & { unlock: UnlockState };
  /** Synced changes are waiting for a lock's unlock before they apply here. */
  pendingSync?: boolean;
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
  /** The host lets this retreat be changed from `saveRetreat` now (a draft or not yet started). */
  canEdit?: boolean;
  /** Present when `canEdit`, so the editor can open on what is saved. */
  goal?: string;
  changePolicy?: ChangePolicy;
  /** Selected ids, all of them from `groupChoices`. */
  groupIDs?: string[];
  /**
   * The groups an edit may choose from: this retreat's own copies, then
   * Blocking Groups it does not hold yet. A new retreat chooses from `groups`.
   */
  groupChoices?: { id: string; name: string }[];
  /** Progress of this running retreat's change policy (with `retreatChanges`). */
  unlock?: UnlockState;
}
/** A whole retreat to save. Without `id` it is new. The host re-validates all of it. */
export interface RetreatDraft {
  id?: string;
  name: string;
  goal: string;
  startsAt: string;
  endsAt: string;
  groupIDs: string[];
  changePolicy: ChangePolicy;
  /** Start (or schedule, when `startsAt` is later) instead of keeping a draft. */
  startNow: boolean;
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
    /** Locked groups whose looser version arrived without this device's unlock. */
    held?: { name: string; appliesAt: string }[];
    /** Short banner word(s), e.g. "WEB FILTER ON". Falls back to title. */
    headline?: string;
    /** Why blocking cannot be turned on right now, in the host's words. */
    problem?: string;
    actions?: EnforcementAction[];
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
  lockdown: null | {
    endsAt: string;
    groupNames: string[];
    detail: string;
    /** Each running session, so one can be ended early by its typed passage. */
    sessions?: { id: string; endsAt: string; groupNames: string[] }[];
  };
  /** With `lockdownPolicy`: what a new lockdown may choose. The host re-validates. */
  lockdownOptions?: { hours: number[]; locks: LockdownLock["kind"][] };
  /** With `debugTrace`. */
  debugTrace?: { recording: boolean };
  /** With `protection`. */
  protection?: Protection;
  /** With `accessRequests`: the oldest unanswered request from a block screen. */
  accessRequest?: { id: string; groupIDs: string[]; minutes?: number };
}
export interface LockdownLock {
  kind: "passage" | "delay" | "checkpoints";
  words: number;
  delayDays: number;
}
export type Command =
  | { type: "snapshot" }
  | { type: "setAppearance"; key: "theme" | "accent"; value: string }
  | { type: "setEnforcement"; revision: string; enabled: boolean }
  | { type: "enforcementAction"; revision: string; id: string }
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
  /** Without `retreatForm` the host opens its own retreat editor. */
  | { type: "createRetreat"; revision: string }
  | { type: "saveRetreat"; revision: string; retreat: RetreatDraft }
  /** Without groups and hours the host opens its own lockdown window. */
  | {
      type: "startLockdown";
      revision: string;
      groupIDs?: string[];
      hours?: number;
      /** With `lockdownPolicy`. Without it the host uses one typed passage. */
      lock?: LockdownLock;
    }
  | { type: "endLockdown"; revision: string; sessionID: string }
  | { type: "installPreset"; revision: string; presetID: string }
  | { type: "pickApplications"; groupID: string }
  | { type: "diagnostics"; names?: boolean; copy?: boolean }
  | { type: "exportDiagnostics"; names: boolean }
  | { type: "classifyWebsites"; domains: string[] }
  | { type: "cancelGroupUnlock"; revision: string; groupID: string }
  | { type: "requestRetreatUnlock"; revision: string; retreatID: string }
  | { type: "cancelRetreatUnlock"; revision: string; retreatID: string }
  | { type: "recreateRetreat"; revision: string; retreatID: string }
  | { type: "setDebugTrace"; enabled: boolean }
  | { type: "exportDebugTrace" }
  | { type: "clearDebugTrace" }
  | { type: "setAntiUninstall"; revision: string; enabled: boolean }
  | { type: "saveAppLock"; revision: string; settings: AppLockSettings }
  | { type: "requestAppUnlock"; revision: string }
  | { type: "cancelAppUnlock"; revision: string }
  | { type: "syncNow" }
  | { type: "resetScreenTime"; revision: string }
  | {
      type: "answerAccessRequest";
      revision: string;
      requestID: string;
      groupID: string;
      minutes: number;
      reason: Exclude<Bypass["reason"], "unspecified">;
      reflection: string;
    }
  | { type: "dismissAccessRequest"; requestID: string };
export interface Reply {
  snapshot?: Snapshot;
  applications?: string[];
  applicationSummary?: string;
  selectionToken?: string;
  message?: string;
  challenge?: Challenge;
  diagnostics?: DiagnosticsReport;
  classified?: DomainCategory[];
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
export function isDiagnosticsReport(
  value: unknown,
): value is DiagnosticsReport {
  if (!value || typeof value !== "object") return false;
  const r = value as DiagnosticsReport;
  return (
    typeof r.text === "string" &&
    Array.isArray(r.findings) &&
    r.findings.every(
      (f) =>
        !!f &&
        ["critical", "warning", "note"].includes(f.severity) &&
        typeof f.message === "string" &&
        (f.hint === undefined || typeof f.hint === "string"),
    ) &&
    (r.journal === undefined ||
      (Array.isArray(r.journal) &&
        r.journal.every(
          (j) =>
            !!j &&
            isDate(j.at) &&
            typeof j.title === "string" &&
            typeof j.detail === "string",
        )))
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
        typeof r.canRequestEnd === "boolean" &&
        (r.canEdit === undefined || typeof r.canEdit === "boolean") &&
        (r.goal === undefined || typeof r.goal === "string") &&
        (r.changePolicy === undefined || isChangePolicy(r.changePolicy)) &&
        (r.groupIDs === undefined || strings(r.groupIDs)) &&
        (r.unlock === undefined || isUnlock(r.unlock)) &&
        (r.groupChoices === undefined ||
          (Array.isArray(r.groupChoices) &&
            r.groupChoices.every(
              (c) =>
                !!c && typeof c.id === "string" && typeof c.name === "string",
            ))),
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
    (s.enforcement.problem === undefined ||
      typeof s.enforcement.problem === "string") &&
    (s.enforcement.actions === undefined ||
      (Array.isArray(s.enforcement.actions) &&
        s.enforcement.actions.every(
          (a) =>
            !!a &&
            typeof a.id === "string" &&
            typeof a.label === "string" &&
            (a.detail === undefined || typeof a.detail === "string") &&
            (a.running === undefined || typeof a.running === "boolean") &&
            (a.placement === undefined ||
              ["problem", "controls"].includes(a.placement)) &&
            (a.danger === undefined || typeof a.danger === "boolean"),
        ))) &&
    (s.enforcement.held === undefined ||
      (Array.isArray(s.enforcement.held) &&
        s.enforcement.held.every(
          (h) => !!h && typeof h.name === "string" && isDate(h.appliesAt),
        ))) &&
    (s.lockdownOptions === undefined ||
      (!!s.lockdownOptions &&
        Array.isArray(s.lockdownOptions.hours) &&
        s.lockdownOptions.hours.length > 0 &&
        s.lockdownOptions.hours.every((h) => integer(h, 1, 8760)) &&
        Array.isArray(s.lockdownOptions.locks) &&
        s.lockdownOptions.locks.every((k) =>
          ["passage", "delay", "checkpoints"].includes(k),
        ))) &&
    (s.debugTrace === undefined ||
      (!!s.debugTrace && typeof s.debugTrace.recording === "boolean")) &&
    (s.protection === undefined || isProtection(s.protection)) &&
    (s.accessRequest === undefined ||
      (!!s.accessRequest &&
        typeof s.accessRequest.id === "string" &&
        strings(s.accessRequest.groupIDs) &&
        (s.accessRequest.minutes === undefined ||
          integer(s.accessRequest.minutes, 1, 1440)))) &&
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
            (r.enforced === undefined || typeof r.enforced === "boolean") &&
            policyKinds.includes(r.lock) &&
            integer(r.delayDays, 0, 365) &&
            typeof r.targets === "string" &&
            (r.temporaryPolicy === undefined ||
              isTemporaryPolicy(r.temporaryPolicy)) &&
            (r.temporaryPassageWords === undefined ||
              integer(r.temporaryPassageWords, 20, 38400)),
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
        s.lockdown.groupNames.every((n) => typeof n === "string") &&
        (s.lockdown.sessions === undefined ||
          (Array.isArray(s.lockdown.sessions) &&
            s.lockdown.sessions.every(
              (v) =>
                !!v &&
                typeof v.id === "string" &&
                isDate(v.endsAt) &&
                strings(v.groupNames),
            )))))
  );
}
const integer = (n: unknown, min: number, max: number) =>
  typeof n === "number" && Number.isInteger(n) && n >= min && n <= max;
const strings = (v: unknown): v is string[] =>
  Array.isArray(v) && v.every((s) => typeof s === "string");
const isDate = (v: unknown) =>
  typeof v === "string" && Number.isFinite(Date.parse(v));
const policyKinds = ["none", "passage", "delay", "checkpoints", "inherited"];
/** Same ids as the Apple hosts' BlockingTargetInput.categories. */
export const websiteCategories = [
  "social",
  "video",
  "news",
  "shopping",
  "gaming",
  "adult",
  "aiTools",
  "productivity",
  "education",
  "finance",
  "health",
  "other",
];
function isChangePolicy(p: unknown): p is ChangePolicy {
  if (!p || typeof p !== "object") return false;
  const v = p as ChangePolicy;
  return (
    policyKinds.includes(v.kind) &&
    integer(v.words, 20, 300) &&
    integer(v.delayDays, 0, 365) &&
    (v.editWindowHours === undefined || integer(v.editWindowHours, 1, 72)) &&
    (v.confirmationWindowHours === undefined ||
      integer(v.confirmationWindowHours, 1, 48))
  );
}
export function isDomainCategories(v: unknown): v is DomainCategory[] {
  return (
    Array.isArray(v) &&
    v.every(
      (d) =>
        !!d &&
        typeof d.domain === "string" &&
        websiteCategories.includes(d.category) &&
        ["appleIntelligence", "heuristic", "user"].includes(d.source),
    )
  );
}
function isUnlock(u: unknown): u is UnlockState {
  if (!u || typeof u !== "object") return false;
  const v = u as UnlockState;
  return (
    ["idle", "waiting", "confirmationDue", "unlocked", "cancelled"].includes(
      v.phase,
    ) &&
    (v.at === undefined || isDate(v.at))
  );
}
export function isAppLockSettings(a: unknown): a is AppLockSettings {
  if (!a || typeof a !== "object") return false;
  const v = a as AppLockSettings;
  return (
    typeof v.enabled === "boolean" &&
    integer(v.unlockDelayDays, 0, 365) &&
    typeof v.repeatConfirmations === "boolean" &&
    integer(v.passageWordCount, 20, 300) &&
    integer(v.confirmationWindowHours, 1, 48) &&
    integer(v.editWindowHours, 1, 72)
  );
}
function isProtection(p: unknown): p is Protection {
  if (!p || typeof p !== "object") return false;
  const v = p as Protection;
  return (
    (v.antiUninstall === undefined ||
      (!!v.antiUninstall && typeof v.antiUninstall.on === "boolean")) &&
    (v.appLock === undefined ||
      (isAppLockSettings(v.appLock) && isUnlock(v.appLock.unlock))) &&
    (v.pendingSync === undefined || typeof v.pendingSync === "boolean")
  );
}
function isNow(n: unknown): n is GroupNow {
  if (!n || typeof n !== "object") return false;
  const v = n as GroupNow;
  return (
    ["lockdown", "paused", "blocking", "upcoming", "idle", "off"].includes(
      v.state,
    ) &&
    typeof v.headline === "string" &&
    (v.changesAt === undefined || isDate(v.changesAt)) &&
    (v.coveredBy === undefined ||
      (!!v.coveredBy &&
        typeof v.coveredBy === "object" &&
        typeof v.coveredBy.name === "string" &&
        typeof v.coveredBy.isComplete === "boolean"))
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
    (v.unlock === undefined || isUnlock(v.unlock)) &&
    (v.mode === undefined || ["block", "allowOnly"].includes(v.mode)) &&
    (v.categories === undefined ||
      (strings(v.categories) &&
        v.categories.every((c) => websiteCategories.includes(c)))) &&
    (v.otherTargets === undefined ||
      (!!v.otherTargets &&
        strings(v.otherTargets.windowsPaths) &&
        strings(v.otherTargets.windowsPublishers))) &&
    (v.domainCategories === undefined ||
      isDomainCategories(v.domainCategories)) &&
    (v.budget === undefined ||
      (!!v.budget &&
        typeof v.budget === "object" &&
        (v.budget.dailyMinutes == null ||
          integer(v.budget.dailyMinutes, 1, 1440)) &&
        (v.budget.weeklyMinutes == null ||
          integer(v.budget.weeklyMinutes, 1, 10080)))) &&
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
    isChangePolicy(v.changePolicy) &&
    isTemporaryPolicy(v.temporaryPolicy)
  );
}
function isTemporaryPolicy(t: unknown): t is TemporaryPolicy {
  const v = t as TemporaryPolicy;
  return (
    !!v &&
    typeof v === "object" &&
    typeof v.allowed === "boolean" &&
    integer(v.words, 20, 300) &&
    integer(v.maximumMinutes, 1, 1440) &&
    (v.resetDays === null || integer(v.resetDays, 1, 365))
  );
}
