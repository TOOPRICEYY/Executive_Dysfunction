export type DiffToken = {
  text: string;
  kind: "matched" | "incorrect" | "missing";
};

export function passageDiff(typed: string, passage: string): DiffToken[] {
  const words = (text: string) => text.trim().split(/\s+/).filter(Boolean);
  const actual = words(typed),
    expected = words(passage);
  const a = actual.map((w) => w.toLowerCase()),
    b = expected.map((w) => w.toLowerCase());
  // Long backoff passages use bounded lookahead instead of a quadratic matrix.
  const bounded = a.length * b.length > 1_000_000;
  const lengths = bounded
    ? []
    : Array.from({ length: a.length + 1 }, () => new Uint32Array(b.length + 1));
  if (!bounded)
    for (let i = a.length - 1; i >= 0; i--)
      for (let j = b.length - 1; j >= 0; j--)
        lengths[i][j] =
          a[i] === b[j]
            ? 1 + lengths[i + 1][j + 1]
            : Math.max(lengths[i + 1][j], lengths[i][j + 1]);
  const result: DiffToken[] = [];
  let i = 0,
    j = 0;
  while (i < a.length && j < b.length) {
    if (a[i] === b[j]) {
      result.push({ text: actual[i++], kind: "matched" });
      j++;
    } else {
      const missing = bounded
        ? b.slice(j + 1, j + 33).includes(a[i]) &&
          !a.slice(i + 1, i + 33).includes(b[j])
        : lengths[i + 1][j] < lengths[i][j + 1];
      result.push(
        missing
          ? { text: expected[j++], kind: "missing" }
          : { text: actual[i++], kind: "incorrect" },
      );
    }
  }
  while (i < a.length) result.push({ text: actual[i++], kind: "incorrect" });
  while (j < b.length) result.push({ text: expected[j++], kind: "missing" });
  return result;
}
