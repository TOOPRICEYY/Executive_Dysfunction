import type { AccessChoice } from "./presentation.ts";
import type { TemporaryPolicy } from "./contract.ts";

/** "1 minute", "10 minutes", "1 hour", "1 hour 30 minutes". */
export function minutesText(minutes: number): string {
  const m = Math.max(0, Math.round(minutes));
  const unit = (n: number, word: string) => `${n} ${word}${n === 1 ? "" : "s"}`;
  if (m < 60) return unit(m, "minute");
  const h = Math.floor(m / 60),
    rest = m % 60;
  return rest ? `${unit(h, "hour")} ${unit(rest, "minute")}` : unit(h, "hour");
}

/** The saved wait; an older host that sends none has no wait. */
export const waitMinutes = (policy: TemporaryPolicy) =>
  Math.min(1440, Math.max(0, policy.waitMinutes ?? 0));

/**
 * When access opens and how long it lasts, said before the person commits.
 * Empty when the group has no wait (access opens as soon as the passage is
 * accepted, as it always has).
 */
export function accessTimingDescription(
  policy: TemporaryPolicy,
  minutes?: number,
): string {
  const wait = waitMinutes(policy);
  if (!wait) return "";
  const opens = `Access opens ${minutesText(wait)} after you finish the passage`;
  return minutes === undefined
    ? `${opens}. Blocking continues until then.`
    : `${opens}, then lasts ${minutesText(minutes)}. Blocking continues until then.`;
}

export function temporaryPassageDescription(
  group: AccessChoice,
  minutes?: number,
): string {
  const timing = accessTimingDescription(group.temporaryPolicy, minutes);
  const prefix = timing ? `${timing} ` : "";
  const base = group.temporaryPolicy.words;
  const current = group.temporaryPassageWords;
  if (current === undefined)
    return `${prefix}Base passage: ${base} words. Your device calculates the current requirement, including increases from previous temporary access.`;
  if (current === base) return `${prefix}Current requirement: ${current} words.`;
  return `${prefix}Current requirement: ${current} words (${base}-word base, increased after previous temporary access).`;
}
