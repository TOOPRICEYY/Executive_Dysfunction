import { useEffect, useState } from "react";
import type { DiagnosticsReport } from "./contract.ts";
import { Modal } from "./components.tsx";
import { when } from "./view-format.ts";

/** The device's own diagnostic report. The host builds it; this only shows it. */
export function DiagnosticsDialog({
  load,
  copy,
  exportReport,
  onClose,
}: {
  load(names: boolean): Promise<DiagnosticsReport | null>;
  /** Asks the host to put the report on the clipboard; resolves to its confirmation. */
  copy(names: boolean): Promise<string | null>;
  /** Asks the host to write the report to files through its own save surface. */
  exportReport?: (names: boolean) => Promise<string | null>;
  onClose(): void;
}) {
  const [names, setNames] = useState(false);
  const [report, setReport] = useState<DiagnosticsReport | null>(null);
  const [status, setStatus] = useState("Collecting state…");
  const refresh = async (withNames: boolean) => {
    setStatus("Collecting state…");
    const next = await load(withNames);
    setReport(next);
    setStatus(next ? "" : "The report could not be read from this device.");
  };
  useEffect(() => {
    void refresh(names);
  }, [names]);
  const critical =
    report?.findings.filter((f) => f.severity === "critical").length ?? 0;
  return (
    <Modal title="Diagnostic report" onClose={onClose} wide>
      <div className="dialog-content">
        <p>
          Full state of this device, including what its blocking component
          itself reports.
        </p>
        <label className="check">
          <input
            type="checkbox"
            checked={names}
            onChange={(e) => setNames(e.target.checked)}
          />
          Include group and site names (otherwise they are replaced by digests)
        </label>
        {status && <p role="status">{status}</p>}
        {report && (
          <>
            <p className={critical ? "diagnostic-critical" : undefined}>
              <strong>
                {critical
                  ? `${critical} critical ${critical === 1 ? "finding" : "findings"}`
                  : report.findings.length
                    ? `${report.findings.length} ${report.findings.length === 1 ? "finding" : "findings"}`
                    : "No inconsistencies detected"}
              </strong>
            </p>
            {report.findings.length > 0 && (
              <ul className="diagnostic-findings">
                {report.findings.map((f, i) => (
                  <li key={i} className={`severity-${f.severity}`}>
                    <strong>{f.severity}</strong> {f.message}
                    {f.hint && <small>{f.hint}</small>}
                  </li>
                ))}
              </ul>
            )}
            {report.journal && (
              <section className="journal" aria-label="Tamper journal">
                <h3>Tamper journal</h3>
                {report.journal.length ? (
                  <ul>
                    {report.journal.map((j, i) => (
                      <li key={i}>
                        <strong>{j.title}</strong>
                        <small>
                          {when(j.at)}
                          {j.detail && ` · ${j.detail}`}
                        </small>
                      </li>
                    ))}
                  </ul>
                ) : (
                  <p>
                    Nothing recorded. Emergency disables, clock changes and the
                    filter being switched off outside Holdfast appear here.
                  </p>
                )}
              </section>
            )}
            <pre className="diagnostic-text" tabIndex={0}>
              {report.text}
            </pre>
          </>
        )}
      </div>
      <div className="dialog-actions">
        <button type="button" onClick={() => void refresh(names)}>
          Refresh
        </button>
        <button
          type="button"
          disabled={!report}
          onClick={async () =>
            setStatus((await copy(names)) ?? "The report could not be copied.")
          }
        >
          Copy report
        </button>
        {exportReport && (
          <button
            type="button"
            disabled={!report}
            onClick={async () =>
              setStatus(
                (await exportReport(names)) ??
                  "The report could not be exported.",
              )
            }
          >
            Export files…
          </button>
        )}
        <button type="button" className="primary" onClick={onClose}>
          Close
        </button>
      </div>
    </Modal>
  );
}
