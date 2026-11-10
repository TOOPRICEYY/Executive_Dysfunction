import { SectionHeading } from "./components.tsx";
import { GroupEditor, newGroup } from "./GroupEditor.tsx";
import { AccessDialog } from "./AccessDialog.tsx";
import { ChallengeDialog } from "./ChallengeDialog.tsx";
import { LockdownDialog } from "./LockdownDialog.tsx";
import { DiagnosticsDialog } from "./DiagnosticsDialog.tsx";
import { RetreatDialog } from "./RetreatDialog.tsx";
import {
  newRetreatForm,
  retreatFormFrom,
  type RetreatForm,
} from "./retreat-form.ts";
import { History } from "./History.tsx";
import { Settings, readPreference, ThemeSwitch } from "./Settings.tsx";
import { Dashboard, useCompact } from "./Dashboard.tsx";
import {
  SquaresFour,
  House,
  ClockCounterClockwise,
  Gear,
  Plus,
  ShieldCheck,
  Stack,
  CaretUp,
} from "@phosphor-icons/react";
import { when } from "./view-format.ts";
import { accessRequestChoices } from "./presentation.ts";
import { useEffect, useRef, useState } from "react";
import { createRoot } from "react-dom/client";
import type {
  Adapter,
  Capability,
  Command,
  Group,
  Reply,
  Snapshot,
  Challenge,
  Preset,
  Retreat,
} from "./contract.ts";
import { isDiagnosticsReport, isDomainCategories } from "./contract.ts";
import { nativeAdapter } from "./bridge.ts";
import { createPreviewAdapter } from "./preview.ts";
import "./style.css";

const native = nativeAdapter();
// Missing native bridge is an error, not permission to silently use fake state.
const adapter =
  native ??
  (new URLSearchParams(location.search).get("preview") === "1"
    ? createPreviewAdapter(
        new URLSearchParams(location.search).get("reference") === "swiftui",
      )
    : null);
type Page = "Status" | "Retreats" | "History" | "Settings";
const pages: Page[] = ["Status", "Retreats", "History"];
const pageIcons = {
  Status: SquaresFour,
  Retreats: House,
  History: ClockCounterClockwise,
  Settings: Gear,
};
function App({ connection }: { connection: Adapter | null }) {
  const [snapshot, setSnapshot] = useState<Snapshot | null>(null);
  const [page, showPage] = useState<Page>("Status");
  const [error, setError] = useState(
    connection
      ? ""
      : "This window is not connected to a Holdfast host. Open the installed app, or explicitly start the isolated UI preview.",
  );
  const [notice, setNotice] = useState("");
  // A notice belongs to the screen it appeared on; do not carry it to the next.
  const setPage = (next: Page) => {
    setNotice("");
    showPage(next);
  };
  const [busy, setBusy] = useState(false);
  const busyRef = useRef(false);
  const [editor, setEditor] = useState<Group | null>(null);
  const editorRevision = useRef("");
  const [access, setAccess] = useState<Group | null>(null);
  const [history, setHistory] = useState<string | null>(null);
  const [lockdownOpen, setLockdownOpen] = useState(false);
  const [diagnosticsOpen, setDiagnosticsOpen] = useState(false);
  const [retreatForm, setRetreatForm] = useState<{
    form: RetreatForm;
    revision: string;
    retreat?: Retreat;
  } | null>(null);
  const [challenge, setChallenge] = useState<Challenge | null>(null);
  const challengeAction = useRef<Command | null>(null);
  const requestSequence = useRef(0);
  const mounted = useRef(true);
  useEffect(() => {
    if (!snapshot?.appearance) return;
    for (const key of ["theme", "accent"] as const) {
      document.documentElement.dataset[key] = snapshot.appearance[key];
      try {
        localStorage.setItem(`holdfast.ui.${key}`, snapshot.appearance[key]);
      } catch {
        /* Session appearance. */
      }
    }
    window.dispatchEvent(new Event("holdfast-appearance"));
  }, [snapshot?.appearance?.theme, snapshot?.appearance?.accent]);
  useEffect(() => {
    if (!snapshot?.capabilities.includes("appearance") || !connection) return;
    const change = (event: Event) => {
      const value = (
        event as CustomEvent<{ key: "theme" | "accent"; value: string }>
      ).detail;
      if (!value) return; // Native snapshot updates do not echo back as writes.
      void connection
        .send({ type: "setAppearance", ...value })
        .catch(() =>
          setError(
            "Appearance could not be saved on this device. Refresh to restore its current settings.",
          ),
        );
    };
    window.addEventListener("holdfast-appearance", change);
    return () => window.removeEventListener("holdfast-appearance", change);
  }, [connection, snapshot?.capabilities.includes("appearance")]);
  const reading = useRef(false);
  const readFailed = useRef(false);
  const request = async (command: Command): Promise<Reply | null> => {
    if (!connection || busyRef.current) return null;
    busyRef.current = true;
    requestSequence.current++;
    setBusy(true);
    setError("");
    readFailed.current = false;
    setNotice("");
    try {
      const reply = await connection.send(command);
      if (!mounted.current) return null;
      if (reply.snapshot) setSnapshot(reply.snapshot);
      else if (command.type === "snapshot")
        throw new Error("The device did not return a status snapshot.");
      if (reply.message) setNotice(reply.message);
      if (reply.challenge) {
        challengeAction.current = command;
        setChallenge(reply.challenge);
      }
      return reply;
    } catch (e) {
      if (mounted.current)
        setError(e instanceof Error ? e.message : "The request failed.");
      // A later background read that succeeds may retire a failed status read.
      if (command.type === "snapshot") readFailed.current = true;
      return null;
    } finally {
      busyRef.current = false;
      if (mounted.current) setBusy(false);
    }
  };
  // Background status reads never disable a control, drop a tap or clear a
  // message someone is reading. On a phone the first touch after the app comes
  // forward also fires "focus"; a blocking read there swallowed that tap.
  const read = async () => {
    if (!connection || document.hidden || busyRef.current || reading.current)
      return;
    // Never let a late read overwrite a mutation.
    const sequence = requestSequence.current;
    reading.current = true;
    try {
      const reply = await connection.send({ type: "snapshot" });
      if (
        !mounted.current ||
        sequence !== requestSequence.current ||
        !reply.snapshot
      )
        return;
      setSnapshot(reply.snapshot);
      if (readFailed.current) setError("");
      readFailed.current = false;
    } catch {
      if (!mounted.current || sequence !== requestSequence.current) return;
      readFailed.current = true;
      setError(
        "Live status could not be refreshed. Blocking state is unconfirmed; reconnect before making changes.",
      );
    } finally {
      reading.current = false;
    }
  };
  useEffect(() => {
    mounted.current = true;
    void request({ type: "snapshot" });
    const refresh = () => void read();
    const timer = setInterval(refresh, 5000);
    window.addEventListener("focus", refresh);
    return () => {
      mounted.current = false;
      clearInterval(timer);
      window.removeEventListener("focus", refresh);
    };
  }, [connection]);
  const supports = (name: Capability) =>
    snapshot?.capabilities.includes(name) ?? false;
  const compact = useCompact();
  const [controlsOpen, setControlsOpen] = useState(false);
  const [plusOpen, setPlusOpen] = useState(false);
  const edit = (group: Group) => {
    editorRevision.current = snapshot?.revision ?? "";
    setEditor(structuredClone(group));
  };
  const newBlockingGroup = supports("editGroups")
    ? () => edit(newGroup())
    : undefined;
  // Hosts that have not moved their lockdown or diagnostics screen yet still
  // open their own window from the bare command.
  const lockdown =
    supports("lockdown") && snapshot
      ? supports("lockdownForm")
        ? () => {
            setError("");
            setLockdownOpen(true);
          }
        : () =>
            void request({
              type: "startLockdown",
              revision: snapshot.revision,
            })
      : undefined;
  const newRetreat =
    supports("retreats") && snapshot
      ? supports("retreatForm")
        ? () => {
            setError("");
            setRetreatForm({
              form: newRetreatForm(),
              revision: snapshot.revision,
            });
          }
        : () =>
            void request({ type: "createRetreat", revision: snapshot.revision })
      : undefined;
  // Only what the host marks editable (a draft, or one not started yet).
  const editRetreat =
    supports("retreatForm") && snapshot
      ? (retreat: Retreat) => {
          setError("");
          setRetreatForm({
            form: retreatFormFrom(retreat),
            revision: snapshot.revision,
            retreat,
          });
        }
      : undefined;
  /** An unlock is a change too; an open retreat edit continues on its revision. */
  const keepRetreatRevision = (revision: string) =>
    setRetreatForm((old) => (old ? { ...old, revision } : old));
  const preset =
    supports("presets") && snapshot
      ? (p: Preset) =>
          void request({
            type: "installPreset",
            revision: snapshot.revision,
            presetID: p.id,
          })
      : undefined;
  const diagnostics = supports("diagnostics")
    ? supports("diagnosticsReport")
      ? () => setDiagnosticsOpen(true)
      : () => void request({ type: "diagnostics" })
    : undefined;
  const exportReport =
    supports("diagnosticsExport") && connection
      ? async (names: boolean) => {
          // Like copying: read-only, outside `request`, never disables the page.
          try {
            const reply = await connection.send({
              type: "exportDiagnostics",
              names,
            });
            return reply.message ?? "Exported the report.";
          } catch (e) {
            return e instanceof Error ? e.message : null;
          }
        }
      : undefined;
  const recreateRetreat =
    supports("recreateRetreat") && snapshot
      ? (r: Retreat) =>
          void request({
            type: "recreateRetreat",
            revision: snapshot.revision,
            retreatID: r.id,
          }).then((reply) => reply && showPage("Retreats"))
      : undefined;
  // A running retreat may be edited only on a host that gates the weakening edits.
  const editable = (r: Retreat) =>
    !!r.canEdit &&
    (r.state === "draft" ||
      r.state === "scheduled" ||
      (r.state === "active" && supports("retreatChanges")));
  const [accessRequestOpen, setAccessRequestOpen] = useState(false);
  const accessRequest = supports("accessRequests")
    ? snapshot?.accessRequest
    : undefined;
  const requestGroups =
    accessRequest && snapshot
      ? accessRequestChoices(snapshot, accessRequest.groupIDs)
      : [];
  const enforcementTitle =
    snapshot?.platform === "ios"
      ? "Screen Time"
      : snapshot?.platform === "macos"
        ? "Web enforcement"
        : "Device enforcement";
  const navigation = (
    <nav aria-label="Main navigation">
      {(compact ? [...pages, "Settings" as Page] : pages).map((p) => {
        const Icon = pageIcons[p];
        return (
          <button
            key={p}
            aria-current={page === p ? "page" : undefined}
            onClick={() => setPage(p)}
          >
            <Icon size={compact ? 22 : 20} aria-hidden="true" />
            <span>{p === "Status" ? "Dashboard" : p}</span>
          </button>
        );
      })}
    </nav>
  );
  const retreatList =
    snapshot?.retreats.filter((r) =>
      page === "History"
        ? r.state === "completed" || r.state === "cancelled"
        : r.state === "active" ||
          r.state === "scheduled" ||
          r.state === "draft",
    ) ?? [];
  return (
    <div className={`app-shell${compact ? " compact" : ""}`}>
      {snapshot?.platform === "preview" && (
        <div className="app-toolbar">
          <span>
            <b>UI preview</b> Enforcement and iCloud writes are disabled
          </span>
        </div>
      )}
      {compact ? (
        <header className="top-bar">
          {page === "Status" ? (
            <span className="top-title">Dashboard</span>
          ) : (
            <h1 className="top-title">{page}</h1>
          )}
          {page === "Status" && snapshot && (
            <div className="plus-menu">
              <button
                aria-label="Add"
                aria-expanded={plusOpen}
                onClick={() => setPlusOpen(!plusOpen)}
              >
                <Plus size={18} weight="bold" aria-hidden="true" />
              </button>
              {plusOpen && (
                <div
                  className="menu-list"
                  role="menu"
                  onClick={() => setPlusOpen(false)}
                >
                  <button
                    role="menuitem"
                    disabled={!lockdown || busy}
                    onClick={lockdown}
                  >
                    <ShieldCheck size={16} aria-hidden="true" /> Lockdown
                  </button>
                  <button
                    role="menuitem"
                    disabled={!newBlockingGroup || busy}
                    onClick={newBlockingGroup}
                  >
                    <Plus size={16} aria-hidden="true" /> New Blocking Group
                  </button>
                  <button
                    role="menuitem"
                    disabled={!newRetreat || busy}
                    onClick={newRetreat}
                  >
                    <House size={16} aria-hidden="true" /> New Retreat
                  </button>
                  {preset &&
                    snapshot.presets?.map((p) => (
                      <button
                        role="menuitem"
                        key={p.id}
                        disabled={busy}
                        onClick={() => preset(p)}
                      >
                        <Stack size={16} aria-hidden="true" /> {p.name}
                      </button>
                    ))}
                </div>
              )}
            </div>
          )}
        </header>
      ) : (
        <aside className="sidebar">
          <a
            className="wordmark"
            href="#status"
            onClick={(e) => {
              e.preventDefault();
              setPage("Status");
            }}
          >
            HOLDFAST
          </a>
          {navigation}
          <button
            className={`device-label tone-${snapshot?.enforcement.state ?? "unknown"}`}
            onClick={() => {
              setPage("Status");
              setControlsOpen(true);
            }}
          >
            <i aria-hidden="true" />
            <span>
              <strong>{enforcementTitle}</strong>
              <span>
                {snapshot
                  ? snapshot.platform === "preview"
                    ? "Preview only"
                    : (snapshot.enforcement.headline ??
                      snapshot.enforcement.title)
                  : "Not connected"}
              </span>
            </span>
            <CaretUp size={12} weight="bold" aria-hidden="true" />
          </button>
          <nav aria-label="Preferences">
            <button
              aria-current={page === "Settings" ? "page" : undefined}
              onClick={() => setPage("Settings")}
            >
              <Gear size={20} aria-hidden="true" />
              Settings
            </button>
          </nav>
          <ThemeSwitch />
        </aside>
      )}
      <main id="main">
        {page !== "Status" && !compact && (
          <header className="page-heading">
            <h1>{page}</h1>
          </header>
        )}
        {page === "Status" && !snapshot && !compact && (
          <header className="page-heading">
            <h1>Dashboard</h1>
          </header>
        )}
        {error && (
          <div role="alert" className="banner error">
            {error}
            {connection && (
              <button
                className="link"
                disabled={busy}
                onClick={() => void request({ type: "snapshot" })}
              >
                Refresh status
              </button>
            )}
          </div>
        )}
        {notice && (
          <div role="status" className="banner">
            {notice}
          </div>
        )}
        {!snapshot && !error && <p role="status">Connecting to this device…</p>}
        {accessRequest && snapshot && (
          <div role="status" className="banner access-request">
            <span>
              A block screen asked for more time
              {accessRequest.minutes
                ? ` (${accessRequest.minutes} minutes)`
                : ""}
              .
            </span>
            <span className="actions">
              <button
                className="primary"
                disabled={busy || !requestGroups.length}
                onClick={() => {
                  setError("");
                  setAccessRequestOpen(true);
                }}
              >
                Answer…
              </button>
              <button
                disabled={busy}
                onClick={() =>
                  void request({
                    type: "dismissAccessRequest",
                    requestID: accessRequest.id,
                  })
                }
              >
                Dismiss
              </button>
            </span>
          </div>
        )}
        {snapshot && (
          <>
            {page === "Status" && (
              <Dashboard
                snapshot={snapshot}
                busy={busy}
                edit={edit}
                onNew={newBlockingGroup}
                onPreset={preset}
                onRetreats={() => setPage("Retreats")}
                onNewRetreat={newRetreat}
                onLockdown={lockdown}
                onHistory={setHistory}
                onDiagnostics={diagnostics}
                controlsOpen={controlsOpen}
                setControlsOpen={setControlsOpen}
                onAction={(id) =>
                  void request({
                    type: "enforcementAction",
                    revision: snapshot.revision,
                    id,
                  })
                }
                onEnforcement={
                  supports("enforcementControl")
                    ? () =>
                        void request({
                          type: "setEnforcement",
                          revision: snapshot.revision,
                          enabled: !snapshot.enforcementEnabled,
                        })
                    : undefined
                }
              />
            )}
            {(page === "Retreats" || page === "History") && (
              <>
                <SectionHeading
                  title={page === "History" ? "Past retreats" : "Live retreats"}
                  detail={
                    page === "History"
                      ? "Completed and ended retreats. Temporary-access history is under Bypasses."
                      : "Only retreats are versioned. Early endings follow the same policy as other changes."
                  }
                  action={
                    page === "Retreats" ? (
                      <button
                        className="primary"
                        disabled={!newRetreat || busy}
                        onClick={newRetreat}
                      >
                        New retreat
                      </button>
                    ) : (
                      <button onClick={() => setHistory("all")}>
                        Bypass history
                      </button>
                    )
                  }
                />
                <section className="object-panel">
                  {retreatList.map((r) => (
                    <article
                      className={`object-row static${r.state === "active" ? " is-blocking" : ""}`}
                      key={r.id}
                    >
                      <span className="state-bar" aria-hidden="true" />
                      <span className="row-copy">
                        <span className="row-title">
                          <strong role="heading" aria-level={2}>
                            {r.name}
                          </strong>
                          <span className="chip">
                            {r.state} · v{r.version}
                          </span>
                        </span>
                        <span className="row-headline">
                          {when(r.startsAt)} — {when(r.endsAt)}
                        </span>
                        <small>{r.groupNames.join(" · ") || "No groups"}</small>
                        <small>Changes: {r.changePolicyLabel}</small>
                      </span>
                      {editRetreat && editable(r) && (
                        <button
                          aria-label={`Edit ${r.name}`}
                          disabled={busy}
                          onClick={() => editRetreat(r)}
                        >
                          Edit
                        </button>
                      )}
                      {recreateRetreat &&
                        (r.state === "completed" ||
                          r.state === "cancelled") && (
                          <button
                            aria-label={`Recreate ${r.name}`}
                            disabled={busy}
                            onClick={() => recreateRetreat(r)}
                          >
                            Recreate
                          </button>
                        )}
                      {["active", "scheduled"].includes(r.state) && (
                        <button
                          disabled={
                            !supports("retreats") || !r.canRequestEnd || busy
                          }
                          onClick={() =>
                            void request({
                              type: "requestRetreatEnd",
                              revision: snapshot.revision,
                              retreatID: r.id,
                            })
                          }
                        >
                          Request early end
                        </button>
                      )}
                    </article>
                  ))}
                  {!retreatList.length && (
                    <p className="panel-empty">
                      {page === "History"
                        ? "No finished retreats yet."
                        : "Plan a longer break using your Blocking Groups."}
                    </p>
                  )}
                </section>
              </>
            )}
            {page === "Settings" && (
              <Settings
                snapshot={snapshot}
                busy={busy}
                send={request}
                onDiagnostics={diagnostics}
              />
            )}
          </>
        )}
        <footer>
          Holdfast · Local interface ·{" "}
          {snapshot ? `Revision ${snapshot.revision}` : "Waiting for device"}
        </footer>
      </main>
      {compact && <div className="tab-bar">{navigation}</div>}
      {editor && snapshot && (
        <GroupEditor
          group={editor}
          isNew={!snapshot.groups.some((g) => g.id === editor.id)}
          live={snapshot.groups.find((g) => g.id === editor.id)}
          onAccess={
            supports("temporaryAccess")
              ? () => {
                  const live = snapshot.groups.find((g) => g.id === editor.id);
                  if (live) setAccess(live);
                }
              : undefined
          }
          onResume={
            supports("temporaryAccess")
              ? () =>
                  void request({
                    type: "cancelTemporaryAccess",
                    revision: snapshot.revision,
                    groupID: editor.id,
                  })
              : undefined
          }
          canSave={supports("editGroups")}
          canPick={supports("pickApplications")}
          details={supports("groupDetails")}
          otherTargets={supports("otherTargets")}
          onClassify={
            supports("classifyWebsites")
              ? async (domains) => {
                  const reply = await request({
                    type: "classifyWebsites",
                    domains,
                  });
                  return reply && isDomainCategories(reply.classified)
                    ? reply.classified
                    : null;
                }
              : undefined
          }
          onCancelUnlock={
            supports("cancelUnlock")
              ? async () => {
                  const reply = await request({
                    type: "cancelGroupUnlock",
                    revision: editorRevision.current,
                    groupID: editor.id,
                  });
                  // Re-locking is a change; keep editing on the new revision.
                  if (reply?.snapshot) {
                    editorRevision.current = reply.snapshot.revision;
                    setEditor((old) =>
                      old
                        ? {
                            ...old,
                            canEdit:
                              reply.snapshot!.groups.find(
                                (g) => g.id === old.id,
                              )?.canEdit ?? false,
                          }
                        : old,
                    );
                  }
                }
              : undefined
          }
          websiteSupport={snapshot.platform !== "windows"}
          onDelete={
            snapshot.groups.some((g) => g.id === editor.id)
              ? async () => {
                  if (
                    await request({
                      type: "deleteGroup",
                      revision: editorRevision.current,
                      groupID: editor.id,
                    })
                  )
                    setEditor(null);
                }
              : undefined
          }
          busy={busy}
          error={error}
          onClose={() => setEditor(null)}
          onPick={() =>
            request({ type: "pickApplications", groupID: editor.id })
          }
          onUnlock={() =>
            void request({
              type: "requestGroupUnlock",
              revision: editorRevision.current,
              groupID: editor.id,
            })
          }
          onSave={async (group) => {
            if (
              await request({
                type: "saveGroup",
                revision: editorRevision.current,
                group,
              })
            )
              setEditor(null);
          }}
        />
      )}
      {access && snapshot && (
        <AccessDialog
          group={access}
          busy={busy}
          error={error}
          onClose={() => setAccess(null)}
          onSubmit={async (minutes, reason, reflection) => {
            if (
              await request({
                type: "requestTemporaryAccess",
                revision: snapshot.revision,
                groupID: access.id,
                minutes,
                reason,
                reflection,
              })
            )
              setAccess(null);
          }}
        />
      )}
      {lockdownOpen && snapshot && (
        <LockdownDialog
          snapshot={snapshot}
          busy={busy}
          error={error}
          onClose={() => setLockdownOpen(false)}
          onEnd={async (sessionID) => {
            // The passage dialog takes over; one modal at a time.
            if (
              await request({
                type: "endLockdown",
                revision: snapshot.revision,
                sessionID,
              })
            )
              setLockdownOpen(false);
          }}
          onSubmit={async (groupIDs, hours, lock) => {
            if (
              await request({
                type: "startLockdown",
                revision: snapshot.revision,
                groupIDs,
                hours,
                ...(lock ? { lock } : {}),
              })
            )
              setLockdownOpen(false);
          }}
        />
      )}
      {retreatForm && snapshot && (
        <RetreatDialog
          snapshot={snapshot}
          initial={retreatForm.form}
          choices={retreatForm.retreat?.groupChoices ?? snapshot.groups}
          status={
            retreatForm.retreat?.state === "draft" ||
            retreatForm.retreat?.state === "scheduled" ||
            retreatForm.retreat?.state === "active"
              ? retreatForm.retreat.state
              : undefined
          }
          unlock={
            snapshot.retreats.find((r) => r.id === retreatForm.retreat?.id)
              ?.unlock
          }
          onRequestUnlock={
            retreatForm.retreat && supports("retreatChanges")
              ? async () => {
                  const reply = await request({
                    type: "requestRetreatUnlock",
                    revision: snapshot.revision,
                    retreatID: retreatForm.retreat!.id,
                  });
                  if (reply?.snapshot)
                    keepRetreatRevision(reply.snapshot.revision);
                }
              : undefined
          }
          onCancelUnlock={
            retreatForm.retreat && supports("cancelUnlock")
              ? async () => {
                  const reply = await request({
                    type: "cancelRetreatUnlock",
                    revision: snapshot.revision,
                    retreatID: retreatForm.retreat!.id,
                  });
                  if (reply?.snapshot)
                    keepRetreatRevision(reply.snapshot.revision);
                }
              : undefined
          }
          busy={busy}
          error={error}
          onClose={() => setRetreatForm(null)}
          onSubmit={async (retreat) => {
            // An edit keeps the revision it opened on, so a change made in
            // between is refused by the host rather than silently overwritten.
            // A new retreat has nothing to overwrite; the host still checks
            // every group it names.
            if (
              await request({
                type: "saveRetreat",
                revision: retreatForm.retreat
                  ? retreatForm.revision
                  : snapshot.revision,
                retreat,
              })
            ) {
              setRetreatForm(null);
              // Keep the host's confirmation visible on the page it describes.
              showPage("Retreats");
            }
          }}
        />
      )}
      {diagnosticsOpen && connection && (
        <DiagnosticsDialog
          onClose={() => setDiagnosticsOpen(false)}
          // Read-only and outside `request`: a report must not disable the
          // dashboard or replace a message someone is reading.
          load={async (names) => {
            try {
              const reply = await connection.send({
                type: "diagnostics",
                names,
              });
              return isDiagnosticsReport(reply.diagnostics)
                ? reply.diagnostics
                : null;
            } catch {
              return null;
            }
          }}
          exportReport={exportReport}
          copy={async (names) => {
            try {
              const reply = await connection.send({
                type: "diagnostics",
                names,
                copy: true,
              });
              return reply.message ?? "Copied the report.";
            } catch {
              return null;
            }
          }}
        />
      )}
      {accessRequestOpen && accessRequest && snapshot && requestGroups[0] && (
        <AccessDialog
          group={requestGroups[0]}
          choices={requestGroups}
          fixedMinutes={accessRequest.minutes}
          intro="A block screen asked for more time. Choose the group it is for; your device shows and verifies the passage before granting it."
          busy={busy}
          error={error}
          onClose={() => setAccessRequestOpen(false)}
          onSubmit={async (minutes, reason, reflection, groupID) => {
            if (
              await request({
                type: "answerAccessRequest",
                revision: snapshot.revision,
                requestID: accessRequest.id,
                groupID,
                minutes,
                reason,
                reflection,
              })
            )
              setAccessRequestOpen(false);
          }}
        />
      )}
      {history && snapshot && (
        <History
          snapshot={snapshot}
          initialGroup={history}
          onClose={() => setHistory(null)}
        />
      )}
      {challenge && (
        <ChallengeDialog
          challenge={challenge}
          busy={busy}
          error={error}
          onClose={() => setChallenge(null)}
          onSubmit={async (typed) => {
            const reply = await request({
              type: "submitChallenge",
              challengeID: challenge.id,
              typed,
            });
            if (reply) {
              setChallenge(null);
              if (
                challengeAction.current?.type === "requestRetreatUnlock" &&
                reply.snapshot
              )
                keepRetreatRevision(reply.snapshot.revision);
              if (
                challengeAction.current?.type === "requestGroupUnlock" &&
                reply.snapshot
              ) {
                editorRevision.current = reply.snapshot.revision;
                setEditor((old) =>
                  old
                    ? {
                        ...old,
                        canEdit:
                          reply.snapshot!.groups.find((g) => g.id === old.id)
                            ?.canEdit ?? false,
                      }
                    : old,
                );
              }
            }
          }}
        />
      )}
    </div>
  );
}
document.documentElement.dataset.theme = readPreference("theme", "light");
document.documentElement.dataset.accent = readPreference(
  "accent",
  "themeDefault",
);
createRoot(document.getElementById("root")!).render(
  <App connection={adapter} />,
);
window.addEventListener("pagehide", () => adapter?.dispose(), { once: true });
