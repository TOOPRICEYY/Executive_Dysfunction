import type {
  AppLockSettings,
  Group,
  LockdownLock,
  UnlockState,
} from "./contract.ts";
import { websiteCategories } from "./contract.ts";

/** Labels for the category ids the hosts share. */
export const categoryLabels: Record<string, string> = {
  social: "Social",
  video: "Video",
  news: "News",
  shopping: "Shopping",
  gaming: "Gaming",
  adult: "Adult",
  aiTools: "AI tools",
  productivity: "Productivity",
  education: "Education",
  finance: "Finance",
  health: "Health",
  other: "Other",
};

/**
 * The draft the editor works on when the host supports `groupDetails`: what
 * the host sent, with the native defaults filled in for a new group.
 */
export function withGroupDetails(group: Group, otherTargets = false): Group {
  return {
    ...group,
    ...(otherTargets
      ? {
          otherTargets: group.otherTargets ?? {
            windowsPaths: [],
            windowsPublishers: [],
          },
        }
      : {}),
    mode: group.mode ?? "block",
    categories: group.categories ?? [],
    budget: {
      dailyMinutes: group.budget?.dailyMinutes ?? null,
      weeklyMinutes: group.budget?.weeklyMinutes ?? null,
    },
    changePolicy: {
      ...group.changePolicy,
      editWindowHours: group.changePolicy.editWindowHours ?? 24,
      confirmationWindowHours: group.changePolicy.confirmationWindowHours ?? 24,
    },
  };
}

const whole = (n: unknown, min: number, max: number) =>
  typeof n === "number" && Number.isInteger(n) && n >= min && n <= max;

/** The first obvious problem with the details, or "". The host re-validates. */
export function groupDetailsProblem(group: Group): string {
  if (group.categories?.some((c) => !websiteCategories.includes(c)))
    return "Choose supported website categories.";
  const daily = group.budget?.dailyMinutes;
  const weekly = group.budget?.weeklyMinutes;
  if (daily != null && !whole(daily, 1, 1440))
    return "A daily limit runs from 1 to 1,440 minutes.";
  if (weekly != null && !whole(weekly, 1, 10080))
    return "A weekly limit runs from 1 to 10,080 minutes.";
  const edit = group.changePolicy.editWindowHours;
  if (edit !== undefined && !whole(edit, 1, 72))
    return "The edit window runs from 1 to 72 hours.";
  const checkpoint = group.changePolicy.confirmationWindowHours;
  if (checkpoint !== undefined && !whole(checkpoint, 1, 48))
    return "The checkpoint window runs from 1 to 48 hours.";
  return "";
}

export function appLockProblem(settings: AppLockSettings): string {
  if (!whole(settings.unlockDelayDays, 0, 365))
    return "Choose an unlock wait of up to 365 days.";
  if (!whole(settings.passageWordCount, 20, 300))
    return "Choose a passage of 20 to 300 words.";
  if (!whole(settings.confirmationWindowHours, 1, 48))
    return "The checkpoint window runs from 1 to 48 hours.";
  if (!whole(settings.editWindowHours, 1, 72))
    return "The edit window runs from 1 to 72 hours.";
  return "";
}

export function lockdownLockProblem(lock: LockdownLock): string {
  if (!whole(lock.words, 20, 300))
    return "Choose a passage of 20 to 300 words.";
  if (lock.kind !== "passage" && !whole(lock.delayDays, 0, 30))
    return "Choose an extra delay of up to 30 days.";
  return "";
}

/** The payload for a lockdown lock: only waiting modes carry a delay. */
export function lockdownLock(lock: LockdownLock): LockdownLock {
  return { ...lock, delayDays: lock.kind === "passage" ? 0 : lock.delayDays };
}

export interface UnlockView {
  title: string;
  /** Label for asking the host for the next passage, when one can be asked for. */
  request?: string;
  /** Label for re-locking or abandoning, when there is something to close. */
  cancel?: string;
}

/**
 * Words for an unlock the host is tracking. The host decides every phase;
 * this only names it and the step it allows next.
 */
export function unlockView(
  unlock: UnlockState | undefined,
  format: (iso: string) => string,
): UnlockView {
  const at = unlock?.at ? format(unlock.at) : "";
  switch (unlock?.phase) {
    case "waiting":
      return {
        title: at ? `Unlocking · opens ${at}` : "Unlocking",
        cancel: "Abandon unlock",
      };
    case "confirmationDue":
      return {
        title: at ? `Checkpoint due by ${at}` : "Checkpoint due",
        request: "Type the checkpoint passage…",
        cancel: "Abandon unlock",
      };
    case "unlocked":
      return {
        title: at ? `Unlocked until ${at}` : "Unlocked",
        cancel: "Re-lock now",
      };
    case "cancelled":
      return {
        title: "The last unlock lapsed",
        request: "Start unlock…",
      };
    default:
      return { title: "Locked", request: "Start unlock…" };
  }
}
