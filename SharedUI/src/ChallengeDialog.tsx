import { useEffect, useRef, useState } from "react";
import type { Challenge } from "./contract.ts";
import { Modal } from "./components.tsx";
import { passageDiff } from "./passage-diff.ts";

// Render one manageable page at a time, including very long backoff passages.
// This prevents direct selection/copy, not screenshots or determined automation.
function Passage({ passage }: { passage: string }) {
  const canvas = useRef<HTMLCanvasElement>(null);
  const [page, setPage] = useState(0);
  const words = passage.split(/\s+/);
  const pages = Math.ceil(words.length / 80);
  useEffect(() => {
    const element = canvas.current;
    if (!element) return;
    const draw = () => {
      const width = element.clientWidth;
      if (width < 1) return;
      const scale = devicePixelRatio || 1;
      const context = element.getContext("2d")!;
      context.font = "16px ui-monospace, monospace";
      const lines: string[] = [];
      let line = "";
      for (const word of words.slice(page * 80, (page + 1) * 80)) {
        if (context.measureText(`${line} ${word}`).width > width - 32 && line) {
          lines.push(line);
          line = word;
        } else line += (line ? " " : "") + word;
      }
      if (line) lines.push(line);
      const height = Math.max(80, lines.length * 29 + 32);
      element.width = width * scale;
      element.height = height * scale;
      element.style.height = `${height}px`;
      context.scale(scale, scale);
      context.font = "16px ui-monospace, monospace";
      context.fillStyle = getComputedStyle(element).color;
      lines.forEach((text, i) => context.fillText(text, 16, 30 + i * 29));
    };
    const observer = new ResizeObserver(draw);
    observer.observe(element);
    draw();
    return () => observer.disconnect();
  }, [passage, page]);
  return (
    <div className="passage">
      <canvas
        ref={canvas}
        role="img"
        aria-label={`Confirmation passage, page ${page + 1}: ${words.slice(page * 80, (page + 1) * 80).join(" ")}`}
      />
      {pages > 1 && (
        <div className="actions">
          <button
            type="button"
            disabled={page === 0}
            onClick={() => setPage(page - 1)}
          >
            Previous passage page
          </button>
          <span>
            {page + 1} / {pages}
          </span>
          <button
            type="button"
            disabled={page + 1 === pages}
            onClick={() => setPage(page + 1)}
          >
            Next passage page
          </button>
        </div>
      )}
    </div>
  );
}
export function ChallengeDialog({
  challenge,
  busy,
  error,
  onClose,
  onSubmit,
}: {
  challenge: Challenge;
  busy: boolean;
  error: string;
  onClose(): void;
  onSubmit(typed: string): Promise<void>;
}) {
  const [typed, setTyped] = useState("");
  const [comparison, setComparison] = useState<ReturnType<
    typeof passageDiff
  > | null>(null);
  useEffect(() => {
    setTyped("");
    setComparison(null);
  }, [challenge.id]);
  const [now, setNow] = useState(Date.now());
  useEffect(() => {
    const timer = setInterval(() => setNow(Date.now()), 1000);
    return () => clearInterval(timer);
  }, []);
  const expired = now >= Date.parse(challenge.expiresAt);
  return (
    <Modal title={challenge.title} onClose={onClose} busy={busy} wide>
      <form
        onSubmit={(e) => {
          e.preventDefault();
          void onSubmit(typed);
        }}
      >
        <div className="dialog-content">
          <p>{challenge.detail}</p>
          {error && (
            <div role="alert" className="banner error">
              {error}
            </div>
          )}
          <Passage passage={challenge.passage} />
          <small>
            Confirmation passage:{" "}
            {challenge.passage.trim().split(/\s+/).filter(Boolean).length}{" "}
            words.
          </small>
          <label>
            Type the confirmation passage
            <textarea
              rows={5}
              autoComplete="off"
              autoCorrect="off"
              spellCheck={false}
              autoCapitalize="none"
              value={typed}
              onChange={(e) => setTyped(e.target.value)}
              onPaste={(e) => e.preventDefault()}
              onDrop={(e) => e.preventDefault()}
            />
          </label>
          <button
            type="button"
            disabled={busy || !typed.trim()}
            onClick={() => setComparison(passageDiff(typed, challenge.passage))}
          >
            {comparison ? "Check again" : "Check passage"}
          </button>
          {comparison && (
            <section
              aria-label="Passage comparison"
              className="passage-comparison"
            >
              <p>Correct · Incorrect · Struck = missing</p>
              <div
                className="passage-diff"
                role="status"
                aria-label={`${comparison.filter((t) => t.kind === "matched").length} correct words, ${comparison.filter((t) => t.kind === "incorrect").length} incorrect words, ${comparison.filter((t) => t.kind === "missing").length} missing words`}
              >
                {comparison.map((token, i) => (
                  <span key={i} className={`diff-${token.kind}`}>
                    {token.text}{" "}
                  </span>
                ))}
              </div>
              <small>
                Comparison is from your last check. After editing, check again.
              </small>
            </section>
          )}
          {expired ? (
            <p role="status">
              This passage expired. Close it and request a new one.
            </p>
          ) : (
            <small>
              Case and extra whitespace do not matter. Paste and drag-and-drop
              are disabled. Your device verifies this passage.
            </small>
          )}
        </div>
        <div className="dialog-actions">
          <button type="button" disabled={busy} onClick={onClose}>
            Cancel
          </button>
          <button
            className="primary"
            disabled={busy || expired || !typed.trim()}
          >
            Confirm passage
          </button>
        </div>
      </form>
    </Modal>
  );
}
