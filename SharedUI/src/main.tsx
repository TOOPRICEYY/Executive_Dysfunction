import { SectionHeading } from "./components.tsx";
import { GroupEditor, newGroup } from "./GroupEditor.tsx";
import { AccessDialog } from "./AccessDialog.tsx";
import { ChallengeDialog } from "./ChallengeDialog.tsx";
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
} from "./contract.ts";
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
  const [page, setPage] = useState<Page>("Status");
  const [error, setError] = useState(
    connection
      ? ""
      : "This window is not connected to a Holdfast host. Open the installed app, or explicitly start the isolated UI preview.",
  );
  const [notice, setNotice] = useState("");
  const [busy, setBusy] = useState(false);
  const busyRef = useRef(false);
  const [editor, setEditor] = useState<Group | null>(null);
  const editorRevision = useRef("");
  const [access, setAccess] = useState<Group | null>(null);
  const [history, setHistory] = useState<string | null>(null);
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
  const request = async (command: Command): Promise<Reply | null> => {
    if (!connection || busyRef.current) return null;
    busyRef.current = true;
    requestSequence.current++;
    setBusy(true);
    setError("");
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
      return null;
    } finally {
      busyRef.current = false;
      if (mounted.current) setBusy(false);
    }
  };
  useEffect(() => {
    mounted.current = true;
    void request({ type: "snapshot" });
    const refresh = () => {
      if (!document.hidden && !busyRef.current)
        void request({ type: "snapshot" });
    };
    // Only read status in the background. Never let a late read overwrite a mutation.
    let polling = false;
    const timer = setInterval(async () => {
      if (!connection || document.hidden || busyRef.current || polling) return;
      const sequence = requestSequence.current;
      polling = true;
      try {
        const reply = await connection.send({ type: "snapshot" });
        if (
          mounted.current &&
          sequence === requestSequence.current &&
          reply.snapshot
        )
          setSnapshot(reply.snapshot);
      } catch {
        if (mounted.current && sequence === requestSequence.current)
          setError(
            "Live status could not be refreshed. Blocking state is unconfirmed; reconnect before making changes.",
          );
      } finally {
        polling = false;
      }
    }, 5000);
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
  const lockdown =
    supports("lockdown") && snapshot
      ? () =>
          void request({ type: "startLockdown", revision: snapshot.revision })
      : undefined;
  const newRetreat =
    supports("retreats") && snapshot
      ? () =>
          void request({ type: "createRetreat", revision: snapshot.revision })
      : undefined;
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
    ? () => void request({ type: "diagnostics" })
    : undefined;
  const advanced = supports("advancedControls")
    ? () => void request({ type: "openAdvancedControls" })
    : undefined;
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
          <span className="top-title">
            {page === "Status" ? "Dashboard" : page}
          </span>
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
        {page !== "Status" && (
          <header className="page-heading">
            <h1>{page}</h1>
          </header>
        )}
        {page === "Status" && !snapshot && (
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
                onAdvanced={advanced}
                onDiagnostics={diagnostics}
                controlsOpen={controlsOpen}
                setControlsOpen={setControlsOpen}
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
                onAdvancedControls={advanced}
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
