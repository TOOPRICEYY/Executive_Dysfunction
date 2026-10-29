import type { Group } from "./contract.ts";

export function temporaryPassageDescription(group: Group): string {
  const base = group.temporaryPolicy.words;
  const current = group.temporaryPassageWords;
  if (current === undefined)
    return `Base passage: ${base} words. Your device calculates the current requirement, including increases from previous temporary access.`;
  if (current === base) return `Current requirement: ${current} words.`;
  return `Current requirement: ${current} words (${base}-word base, increased after previous temporary access).`;
}
